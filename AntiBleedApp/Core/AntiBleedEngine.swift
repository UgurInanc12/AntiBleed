import Foundation

/// Abstraction over the echo canceller so the engine can be unit-tested with a
/// deterministic fake and shipped with AECBridge (WebRTC AEC3) on macOS.
public protocol EchoCanceller: AnyObject {
    /// Far-end reference frame. Must precede the matching capture frame.
    func processRender(_ render: [Float])
    /// Near-end capture frame. Returns the echo-cancelled frame (same length).
    func processCapture(_ capture: [Float]) -> [Float]
    func stats() -> AECStats
    func reset()
    /// False when no real engine is linked (passthrough build). The engine then
    /// never leaves BYPASS, so the virtual mic is simply the raw microphone.
    var isRealAEC: Bool { get }
}

/// Real-time telemetry snapshot published to the UI on a throttled timer
/// (never per frame, PLAN 39).
public struct EngineTelemetry: Equatable {
    public var state: PipelineState = .stopped
    public var output: String = "silence"
    public var rawMicRmsDb: Float = -.infinity
    public var renderRmsDb: Float = -.infinity
    public var cleanedRmsDb: Float = -.infinity
    public var couplingScore: Float = 0
    public var couplingCorrelation: Float = 0
    public var aec: AECStats = AECStats()
    public var sync: AudioSynchronizer.SyncStats = AudioSynchronizer.SyncStats()
    public var framesProcessed: UInt64 = 0
    public var transitions: UInt64 = 0
    /// Samples the raw path is delayed by to match the AEC path (D-020).
    public var pathAlignmentSamples: Int = 0
    public init() {}
}

/// Platform-independent heart of Anti-Bleed_mic (PLAN 12, 13, 19).
///
/// For every time-aligned (render, mic) pair:
///   1. render -> AEC reverse stream (always, so the filter stays warm),
///   2. mic    -> AEC capture stream -> cleaned,
///   3. coupling detector + render activity + AEC health -> safety FSM,
///   4. FSM selects raw / processed / crossfade / silence,
///   5. selected frame goes to the virtual-mic writer.
///
/// The hard invariant (D-008) is structural: the only candidate outputs are the
/// raw mic frame, the AEC output frame, a convex combination of the two, or
/// zeros. The render frame is never a candidate.
///
/// The raw candidate is delayed by the AEC's own processing latency (D-020) so
/// both candidates describe the same instant. Without that, every switch or
/// crossfade splices two points in time and is heard as a skip.
public final class AntiBleedEngine {
    public let aec: EchoCanceller
    public let synchronizer: AudioSynchronizer
    public let coupling = CouplingDetector()
    public let fsm = SafetyStateMachine()
    public var renderActivity = RenderActivityDetector()

    /// User toggle "Echo cancellation". When false the engine stays in BYPASS
    /// (raw mic) but still feeds AEC so re-enabling converges instantly.
    public var aecEnabled: Bool = true

    /// Set while the selected reference output is not the one macOS actually
    /// plays through (headphones, AirPlay, a dock). There is no bleed to remove
    /// and AEC3 would attenuate the near-end voice by ~6 dB, so the engine holds
    /// BYPASS and passes the raw microphone through untouched. Audio keeps
    /// flowing to the virtual mic: the app must never go silent mid-call (D-020).
    /// The AEC still runs so re-selecting the speakers converges immediately.
    public var referenceOutputActive: Bool = true

    /// Whether the FSM may expose processed audio right now.
    public var aecUsable: Bool { aecEnabled && referenceOutputActive && aec.isRealAEC }

    /// Run the (comparatively expensive) coupling analysis every N frames (10 = 100 ms).
    public var couplingEveryNFrames: Int = 10

    /// Samples the raw path is delayed by to match the AEC path. Measured from
    /// the canceller at init; 0 means "no real AEC, nothing to align".
    public private(set) var pathAlignmentSamples: Int = 0

    public private(set) var telemetry = EngineTelemetry()
    private var lastCoupling = CouplingResult()
    private var frameCounter: UInt64 = 0
    private var pendingRouteChange = false
    private var rawDelay = DelayLine()
    private var lastAlignedRaw: [Float] = []
    private var lastCleaned: [Float] = []

    /// Last frame's raw candidate (delay-aligned mic). Exposed for tests that
    /// verify the two candidates describe the same instant.
    public var rawCandidateForTesting: [Float] { lastAlignedRaw }
    /// Last frame's AEC candidate.
    public var aecCandidateForTesting: [Float] { lastCleaned }

    public init(aec: EchoCanceller, synchronizer: AudioSynchronizer = AudioSynchronizer()) {
        self.aec = aec
        self.synchronizer = synchronizer
        alignPaths()
    }

    /// Measures the canceller's input-to-output latency and delays the raw path
    /// by the same amount. Safe to call again after a route change; the AEC is
    /// reset by the measurement itself.
    public func alignPaths() {
        let measured = EchoCancellerLatency.measure(aec)
        pathAlignmentSamples = measured
        rawDelay.setDelay(measured)
        telemetry.pathAlignmentSamples = measured
    }


    public var state: PipelineState { fsm.state }

    public func start() {
        fsm.start()
        telemetry.state = fsm.state
    }

    public func stop() {
        fsm.stop()
        synchronizer.reset()
        telemetry.state = fsm.state
    }

    /// Call when the selected mic or output device changes (PLAN 13.7, D-012):
    /// output snaps to raw mic, AEC state is discarded, FSM re-probes.
    public func notifyRouteChanged() {
        pendingRouteChange = true
        aec.reset()
        coupling.reset()
        renderActivity.reset()
        synchronizer.reset()
        rawDelay.reset()
        lastCoupling = CouplingResult()
    }

    /// Processes one aligned pair. Returns the frame to expose on the virtual mic.
    public func process(render: AudioFrame, mic: AudioFrame) -> AudioFrame {
        frameCounter += 1

        // 1-2. AEC always runs (keeps adapting even in BYPASS, PLAN 12.3).
        aec.processRender(render.samples)
        let cleaned = aec.processCapture(mic.samples)
        let aecStats = aec.stats()

        // Raw candidate delayed to the AEC's latency so both candidates describe
        // the same instant (D-020). Detection below still uses the undelayed mic:
        // it is compared against the undelayed render.
        let alignedRaw = rawDelay.process(mic.samples)
        lastAlignedRaw = alignedRaw
        lastCleaned = cleaned

        // 3. Detectors.
        let activity = renderActivity.update(renderRmsDb: render.rmsDb)
        coupling.push(render: render.samples, mic: mic.samples)
        if frameCounter % UInt64(max(1, couplingEveryNFrames)) == 0 {
            lastCoupling = coupling.evaluate(aecStats: aecStats)
        }

        // 4. Safety FSM.
        let routeChanged = pendingRouteChange
        pendingRouteChange = false
        let selection = fsm.update(renderActivity: activity,
                                   coupling: lastCoupling,
                                   aecStats: aecStats,
                                   aecAvailable: aecUsable,
                                   routeChanged: routeChanged)

        // 5. Output selection. Candidates: aligned raw mic, cleaned, mix, zeros.
        let outSamples: [Float]
        let outName: String
        switch selection {
        case .rawMic:
            outSamples = alignedRaw; outName = "raw"
        case .aecProcessed:
            outSamples = cleaned; outName = "aec"
        case .crossfade(let p):
            outSamples = Crossfade.equalPower(alignedRaw, cleaned, progress: p); outName = "xfade"
        case .silence:
            outSamples = [Float](repeating: 0, count: mic.samples.count); outName = "silence"
        }

        var out = mic
        out.samples = outSamples
        out.rmsDb = AudioFrame.computeRmsDb(outSamples)

        // Telemetry is a plain value; the UI layer snapshots it on a timer.
        telemetry.state = fsm.state
        telemetry.output = outName
        telemetry.rawMicRmsDb = mic.rmsDb
        telemetry.renderRmsDb = render.rmsDb
        telemetry.cleanedRmsDb = out.rmsDb
        telemetry.couplingScore = lastCoupling.score
        telemetry.couplingCorrelation = lastCoupling.correlation
        telemetry.aec = aecStats
        telemetry.sync = synchronizer.stats
        telemetry.framesProcessed = frameCounter
        telemetry.transitions = fsm.transitionCount
        telemetry.pathAlignmentSamples = pathAlignmentSamples
        return out
    }

    /// Pulls as many aligned pairs as available and processes them.
    /// Returns the produced output frames (possibly empty on underrun).
    public func drain(maxFrames: Int = 8) -> [AudioFrame] {
        var out: [AudioFrame] = []
        var n = 0
        while n < maxFrames, let pair = synchronizer.pullAlignedFrames() {
            out.append(process(render: pair.render, mic: pair.mic))
            n += 1
        }
        return out
    }
}

/// Passthrough canceller used when AECBridge is not linked (Windows/Linux
/// tests, CI without WebRTC). isRealAEC == false keeps the FSM in BYPASS.
public final class PassthroughCanceller: EchoCanceller {
    public init() {}
    public func processRender(_ render: [Float]) {}
    public func processCapture(_ capture: [Float]) -> [Float] { capture }
    public func stats() -> AECStats { AECStats() }
    public func reset() {}
    public var isRealAEC: Bool { false }
}
