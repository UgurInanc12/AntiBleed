import SwiftUI
import Combine
import AntiBleedCore
import AntiBleedAudio

/// UI-facing state (PLAN 17, 18, 24, 27). Owns the pipeline, device manager
/// and permissions; polls pipeline telemetry at 20 Hz for meters.
@available(macOS 14.2, *)
@MainActor
final class AppState: ObservableObject {
    // Persisted selections (UIDs are stable across reboots, IDs are not).
    @AppStorage("antibleed.micUID") var selectedMicUID: String = ""
    @AppStorage("antibleed.outputUID") var selectedOutputUID: String = ""
    @AppStorage("antibleed.autoStart") var autoStart: Bool = true
    /// Echo cancellation only makes sense while macOS actually plays through the
    /// selected reference output (D-020). When the user switches the system
    /// output to something else (headphones, a dock, AirPlay) there is no bleed
    /// to remove and AEC3 would attenuate the near-end voice, so the engine holds
    /// raw mic. The microphone keeps working throughout; only the cancellation
    /// is suspended, and it re-engages when that output is default again.
    @AppStorage("antibleed.pauseWhenOutputNotDefault") var pauseWhenOutputNotDefault: Bool = true

    /// Persisted manually (UserDefaults) so the change can be forwarded to the pipeline.
    @Published var isAECEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAECEnabled, forKey: "antibleed.aecEnabled")
            pipeline.setAECEnabled(isAECEnabled)
        }
    }

    @Published var pipelineState: PipelineState = .stopped
    @Published var snapshot = AntiBleedPipeline.Snapshot()
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var recentTransitions: [String] = []
    /// True while processing is suspended because the selected reference output
    /// is not the current macOS output (D-020). The pipeline resumes by itself.
    @Published var isPausedForOutputRoute = false

    let deviceManager = DeviceManager()
    let permissions = Permissions()
    let pipeline = AntiBleedPipeline()

    private var timer: AnyCancellable?

    init() {
        isAECEnabled = UserDefaults.standard.object(forKey: "antibleed.aecEnabled") as? Bool ?? true
        deviceManager.onDevicesChanged = { [weak self] in self?.handleDevicesChanged() }
        deviceManager.observeDeviceChanges()
        deviceManager.refresh()
        permissions.refreshMicStatus()

        pipeline.onStateChange = { [weak self] from, to in
            guard let self else { return }
            self.pipelineState = to
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.recentTransitions.insert("\(stamp)  \(from.rawValue) -> \(to.rawValue)", at: 0)
            if self.recentTransitions.count > 50 { self.recentTransitions.removeLast() }
        }
        pipeline.onError = { [weak self] msg in self?.lastError = msg }

        timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.snapshot = self.pipeline.currentSnapshot()
            self.pipelineState = self.snapshot.engine.state
        }

        if autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startIfPossible() }
        }
    }

    // MARK: - Derived

    var selectedMic: AudioDevice? { deviceManager.device(uid: selectedMicUID.isEmpty ? nil : selectedMicUID) }
    var selectedOutput: AudioDevice? { deviceManager.device(uid: selectedOutputUID.isEmpty ? nil : selectedOutputUID) }
    var driverInstalled: Bool { deviceManager.virtualMicPresent && deviceManager.virtualWriterPresent }

    var statusLine: String {
        if !isRunning { return "Stopped" }
        if isPausedForOutputRoute {
            let name = selectedOutput?.name ?? "the selected speakers"
            return "Raw microphone: output is not \(name)"
        }
        switch pipelineState {
        case .active: return "Removing speaker bleed"
        case .learning: return "Learning echo path"
        case .probing: return "Checking for speaker bleed"
        case .bypass: return snapshot.engine.renderRmsDb > -55 ? "Speakers playing, no bleed detected" : "Idle (raw microphone)"
        case .degraded: return "Recovering"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    // MARK: - Actions

    func startIfPossible() {
        if selectedMicUID.isEmpty { selectedMicUID = deviceManager.defaultInputUID ?? "" }
        if selectedOutputUID.isEmpty { selectedOutputUID = deviceManager.defaultOutputUID ?? "" }
        guard !selectedMicUID.isEmpty else { lastError = "Select a microphone first."; return }
        start()
    }

    func start() {
        permissions.refreshMicStatus()
        if permissions.mic == .notDetermined {
            Task { @MainActor in
                let s = await permissions.requestMic()
                if s == .granted { self.start() } else { self.lastError = "Microphone permission denied." }
            }
            return
        }
        guard permissions.mic == .granted else {
            lastError = "Microphone access is denied. Open System Settings to allow Anti-Bleed."
            return
        }
        do {
            let cfg = AntiBleedPipeline.Config(micDeviceUID: selectedMicUID,
                                               outputDeviceUID: selectedOutputUID.isEmpty ? nil : selectedOutputUID,
                                               aecEnabled: isAECEnabled)
            try pipeline.start(config: cfg)
            isRunning = true
            lastError = pipeline.currentSnapshot().lastError
            permissions.recordSystemAudioOutcome(granted: pipeline.capture.state == .running)
            // Starting while the system already plays through something else must
            // come up in raw-mic mode, not with the AEC engaged (D-020).
            syncOutputRoutePause()
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            pipelineState = .error
        }
    }

    func stop() {
        pipeline.stop()
        isRunning = false
        pipelineState = .stopped
        // Nothing is running, so the route flag no longer describes anything.
        isPausedForOutputRoute = false
    }

    func selectMic(_ uid: String) {
        selectedMicUID = uid
        if isRunning { restart() }
    }

    func selectOutput(_ uid: String) {
        selectedOutputUID = uid
        if isRunning { restart() }
    }

    private func restart() {
        // start() re-evaluates the route flag through syncOutputRoutePause().
        stop()
        start()
    }

    private func handleDevicesChanged() {
        // Selected device vanished (unplugged / Bluetooth off): fall back to defaults.
        if !selectedMicUID.isEmpty, selectedMic == nil {
            lastError = "Microphone disconnected; switched to system default."
            selectedMicUID = deviceManager.defaultInputUID ?? ""
            if isRunning { restart() }
        }
        if !selectedOutputUID.isEmpty, selectedOutput == nil {
            lastError = "Output device disconnected; switched to system default."
            selectedOutputUID = deviceManager.defaultOutputUID ?? ""
            if isRunning { restart() }
        }
        syncOutputRoutePause()
    }

    /// True when macOS currently plays through the output we use as the AEC
    /// reference. With no output selected there is no reference and no bleed.
    var referenceOutputIsDefault: Bool {
        guard !selectedOutputUID.isEmpty else { return false }
        return deviceManager.defaultOutputUID == selectedOutputUID
    }

    /// Holds the AEC in BYPASS while the system output is not our reference
    /// output, and re-enables it as soon as it is again (D-020).
    ///
    /// This deliberately does NOT stop the pipeline: the virtual microphone must
    /// keep carrying the user's voice, otherwise switching to headphones would
    /// kill the mic in the middle of a call. Only the echo cancellation is
    /// suspended, because with no bleed to remove AEC3 would attenuate the
    /// near-end voice by roughly 6 dB.
    private func syncOutputRoutePause() {
        guard isRunning else {
            if isPausedForOutputRoute { isPausedForOutputRoute = false }
            return
        }
        guard pauseWhenOutputNotDefault else {
            if isPausedForOutputRoute { isPausedForOutputRoute = false }
            pipeline.setReferenceOutputActive(true)
            return
        }
        let onReference = referenceOutputIsDefault
        pipeline.setReferenceOutputActive(onReference)
        if !onReference && !isPausedForOutputRoute {
            isPausedForOutputRoute = true
            let name = selectedOutput?.name ?? "the selected speakers"
            lastError = "Echo cancellation paused: system output is no longer \(name). Microphone still live."
        } else if onReference && isPausedForOutputRoute {
            isPausedForOutputRoute = false
            lastError = nil
        }
    }
}
