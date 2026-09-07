import SwiftUI
import Combine
import AntiBleedCore
import AntiBleedAudio

/// UI-facing state (PLAN 17, 18, 24, 27). Owns the pipeline, device manager
/// and permissions; polls pipeline telemetry at 20 Hz for meters.
@MainActor
final class AppState: ObservableObject {
    // Persisted selections (UIDs are stable across reboots, IDs are not).
    @AppStorage("antibleed.micUID") var selectedMicUID: String = ""
    @AppStorage("antibleed.outputUID") var selectedOutputUID: String = ""
    @AppStorage("antibleed.autoStart") var autoStart: Bool = true

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
    }
}
