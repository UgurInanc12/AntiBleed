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
public final class AntiBleedEngine {
    public let aec: EchoCanceller
    public let synchronizer: AudioSynchronizer
    public let coupling = CouplingDetector()
    public let fsm = SafetyStateMachine()
    public var renderActivity = RenderActivityDetector()

    /// User toggle "Echo cancellation". When false the engine stays in BYPASS
    /// (raw mic) but still feeds AEC so re-enabling converges instantly.
    public var aecEnabled: Bool = true

    /// Run the (comparatively expensive) coupling analysis every N frames (10 = 100 ms).
    public var couplingEveryNFrames: Int = 10

    public private(set) var telemetry = EngineTelemetry()
    private var lastCoupling = CouplingResult()
    private var frameCounter: UInt64 = 0
    private var pendingRouteChange = false

    public init(aec: EchoCanceller, synchronizer: AudioSynchronizer = AudioSynchronizer()) {
        self.aec = aec
        self.synchronizer = synchronizer
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
        lastCoupling = CouplingResult()
    }

    /// Processes one aligned pair. Returns the frame to expose on the virtual mic.
    public func process(render: AudioFrame, mic: AudioFrame) -> AudioFrame {
        frameCounter += 1

        // 1-2. AEC always runs (keeps adapting even in BYPASS, PLAN 12.3).
        aec.processRender(render.samples)
        let cleaned = aec.processCapture(mic.samples)
        let aecStats = aec.stats()

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
                                   aecAvailable: aecEnabled && aec.isRealAEC,
                                   routeChanged: routeChanged)

        // 5. Output selection. Candidates: mic, cleaned, mix(mic, cleaned), zeros.
        let outSamples: [Float]
        let outName: String
        switch selection {
        case .rawMic:
            outSamples = mic.samples; outName = "raw"
        case .aecProcessed:
            outSamples = cleaned; outName = "aec"
        case .crossfade(let p):
            outSamples = Crossfade.equalPower(mic.samples, cleaned, progress: p); outName = "xfade"
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
