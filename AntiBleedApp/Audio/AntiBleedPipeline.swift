#if canImport(CoreAudio)
import Foundation
import CoreAudio
import AntiBleedCore
import AntiBleedRealtime

/// Live pipeline (PLAN 12, 13, 19, 22):
///
///   AggregateCapture (mic + tap IOProc) -> abm_ring -> DSP thread
///   DSP thread: FrameAssembler(mic), FrameAssembler(render) -> AudioSynchronizer
///               -> AntiBleedEngine (AEC3 + coupling + safety FSM) -> VirtualMicWriter
///
/// Heavy work runs on one high-priority worker polling the ring every 2 ms.
/// Telemetry is copied for the UI at 20 Hz; callbacks never take engine locks.
@available(macOS 14.2, *)
public final class AntiBleedPipeline {
    public struct Config: Equatable {
        public var micDeviceUID: String
        public var outputDeviceUID: String?
        public var aecEnabled: Bool = true
        public init(micDeviceUID: String, outputDeviceUID: String?, aecEnabled: Bool = true) {
            self.micDeviceUID = micDeviceUID; self.outputDeviceUID = outputDeviceUID; self.aecEnabled = aecEnabled
        }
    }

    public struct Snapshot {
        public var engine = EngineTelemetry()
        public var captureState = "idle"
        public var writerState = "unresolved"
        public var captureRingOverruns: UInt64 = 0
        public var writerUnderruns: UInt64 = 0
        public var writerOverruns: UInt64 = 0
        public var captureSampleRate: Double = 0
        public var engineName = ""
        public var lastError: String?
        public var running = false
        public init() {}
    }

    private let engine: AntiBleedEngine
    public private(set) var capture = AggregateCapture()
    public private(set) var writer = VirtualMicWriter()
    public private(set) var config: Config?
    private var snapshot = Snapshot()

    /// Called on the main queue on every FSM transition (for logging / UI).
    public var onStateChange: ((PipelineState, PipelineState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnosticTransition: (([String: String]) -> Void)?

    private let micAssembler = FrameAssembler()
    private let renderAssembler = FrameAssembler()
    private var worker: Thread?
    private let runLock = NSLock()
    private let engineLock = NSLock()
    private var runRequested = false
    private var running: Bool {
        get { runLock.lock(); defer { runLock.unlock() }; return runRequested }
        set { runLock.lock(); defer { runLock.unlock() }; runRequested = newValue }
    }
    private let wake = DispatchSemaphore(value: 0)
    private let workerDone = DispatchGroup()
    private let snapshotLock = NSLock()
    private let engineName: String

    public init() {
        if let aec = WebRTCCanceller() {
            engine = AntiBleedEngine(aec: aec)
            engineName = WebRTCCanceller.engineName
        } else {
            engine = AntiBleedEngine(aec: PassthroughCanceller())
            engineName = "passthrough (AECBridge unavailable)"
        }
        snapshot.engineName = engineName
        engine.fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            // Capture the decision metadata now, not from a later UI snapshot.
            let aecStats = engine.aec.stats()
            let fields = ["from": from.rawValue, "to": to.rawValue,
                          "decision_uptime_seconds": String(ProcessInfo.processInfo.systemUptime),
                          "divergence": String(aecStats.divergentFilterFraction),
                          "erle_db": String(aecStats.echoReturnLossEnhancement),
                          "aec_stats_valid": String(aecStats.valid),
                          "reason": engine.fsm.lastTransitionReason,
                          "coupling": String(engine.fsm.couplingConfidence),
                          "aec_delay_ms": engine.fsm.aecDelayMs.map(String.init) ?? "unknown",
                          "aec_enabled": String(engine.aecEnabled),
                          "reference_active": String(engine.referenceOutputActive)]
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(from, to)
                self?.onDiagnosticTransition?(fields)
            }
        }
    }

    // MARK: - Lifecycle

    public func start(config: Config) throws {
        stop()
        guard worker == nil else {
            throw NSError(domain: "AntiBleedPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Previous audio worker is still stopping. Retry Start."])
        }
        snapshotLock.lock(); snapshot.lastError = nil; snapshotLock.unlock()
        self.config = config
        engine.aecEnabled = config.aecEnabled
        // A failure after creating capture or starting the worker must unwind
        // the partially started pipeline before the caller can retry.
        var started = false
        defer { if !started { stop() } }

        do {
            try writer.resolve()
        } catch {
            // No driver: we can still run the DSP for meters/diagnostics, but nothing
            // reaches Discord. Surface it clearly (PLAN 27.6).
            report("Virtual microphone driver not found. Install AntiBleed.driver.")
        }

        try capture.create(micDeviceUID: config.micDeviceUID, outputDeviceUID: config.outputDeviceUID)
        micAssembler.reset(); renderAssembler.reset()
        engine.notifyRouteChanged()
        engine.start()

        if writer.isResolved { try writer.start() }
        try capture.start()
        running = true
        publish()
        workerDone.enter()
        let t = Thread { [weak self] in
            defer { self?.workerDone.leave() }
            self?.dspLoop()
        }
        t.name = "AntiBleed.DSP"
        t.qualityOfService = .userInteractive
        t.threadPriority = 0.9
        worker = t
        t.start()
        started = true
    }

    @discardableResult
    public func stop() -> Bool {
        guard worker != nil || running || capture.state != .idle else { return true }
        running = false
        wake.signal()
        // Never destroy resources still owned by a live worker, or allow a
        // replacement consumer to start on the same ring after a timeout.
        if worker != nil && workerDone.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            report("Audio worker did not stop in time. Resources retained; retry Stop before Start.")
            return false
        }
        capture.stop()
        capture.destroy()
        writer.stop()
        engine.stop()
        worker = nil
        publish()
        return true
    }

    public var isRunning: Bool { running }

    /// Re-route without tearing the UI down (device switch, PLAN 13.7).
    public func reconfigure(_ newConfig: Config) throws {
        guard let current = config else { try start(config: newConfig); return }
        if !isRunning || current.micDeviceUID != newConfig.micDeviceUID || current.outputDeviceUID != newConfig.outputDeviceUID {
            try start(config: newConfig)
        } else {
            config = newConfig
            setAECEnabled(newConfig.aecEnabled)
        }
    }

    public func setAECEnabled(_ enabled: Bool) {
        config?.aecEnabled = enabled
        engineLock.lock(); defer { engineLock.unlock() }
        engine.aecEnabled = enabled
    }

    /// Tells the engine whether the selected reference output is the one macOS
    /// currently plays through. False holds BYPASS (raw mic keeps flowing to the
    /// virtual mic) instead of stopping the pipeline, so the microphone never
    /// dies mid-call when the user switches to headphones (D-020).
    public func setReferenceOutputActive(_ active: Bool) {
        engineLock.lock(); defer { engineLock.unlock() }
        engine.referenceOutputActive = active
    }

    public func currentSnapshot() -> Snapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }

    // MARK: - DSP worker

    private func dspLoop() {
        var view = abm_block_view_t()
        var lastPublish = Date()
        while running {
            var didWork = false
            while running && abm_ring_pop(capture.ring, &view) {
                engineLock.lock()
                defer { engineLock.unlock() }
                didWork = true
                let n = Int(view.frames)
                let micBlock = Array(UnsafeBufferPointer(start: view.mic, count: n))
                let renderBlock = Array(UnsafeBufferPointer(start: view.render, count: n))
                let rate = capture.sampleRate > 0 ? capture.sampleRate : AudioConstants.sampleRate
                for f in micAssembler.push(micBlock, sampleRate: rate, channels: 1, hostTimeNs: view.host_time_ns) {
                    engine.synchronizer.pushMic(f)
                }
                for f in renderAssembler.push(renderBlock, sampleRate: rate, channels: 1, hostTimeNs: view.host_time_ns) {
                    engine.synchronizer.pushRender(f)
                }
                for out in engine.drain() where writer.isResolved {
                    writer.write(out)
                }
            }
            if Date().timeIntervalSince(lastPublish) > 0.05 {
                publish()
                lastPublish = Date()
            }
            if !didWork {
                // 2 ms poll keeps worst-case added latency small without spinning.
                _ = wake.wait(timeout: .now() + .milliseconds(2))
            }
        }
    }

    private func publish() {
        engineLock.lock(); defer { engineLock.unlock() }
        snapshotLock.lock()
        snapshot.engine = engine.telemetry
        snapshot.captureState = capture.state.rawValue
        snapshot.writerState = writer.state.rawValue
        snapshot.captureRingOverruns = abm_ring_overruns(capture.ring)
        snapshot.writerUnderruns = writer.underruns
        snapshot.writerOverruns = writer.overruns
        snapshot.captureSampleRate = capture.sampleRate
        snapshot.lastError = capture.lastError ?? writer.lastError
        snapshot.running = running
        snapshotLock.unlock()
    }

    private func report(_ message: String) {
        snapshotLock.lock(); snapshot.lastError = message; snapshotLock.unlock()
        DispatchQueue.main.async { self.onError?(message) }
    }
}
#endif
