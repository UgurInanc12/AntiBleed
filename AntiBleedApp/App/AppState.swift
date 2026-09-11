import SwiftUI
import Combine
import ServiceManagement
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
    /// Start processing as soon as the device list is known. Default on: the
    /// product is a background utility, the user should not have to press Start
    /// after every login (D-021).
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
    /// Driver install state, refreshed with the device list so the menu bar can
    /// offer a one-click install instead of a shell command (D-023).
    @Published var driverStatus: DriverInstaller.Status = .notInstalled
    @Published var isInstallingDriver = false

    let deviceManager = DeviceManager()
    let permissions = Permissions()
    let pipeline = AntiBleedPipeline()

    private var timer: AnyCancellable?
    /// Autostart must fire exactly once per launch, not on every device change.
    private var hasAutoStarted = false

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

        // First launch: adopt the system defaults and register the login item so
        // the app is running after the next reboot with no user action. Both are
        // one-time and remain user-overridable (Settings -> Launch at login).
        if !UserDefaults.standard.bool(forKey: Self.didFirstRunKey) {
            UserDefaults.standard.set(true, forKey: Self.didFirstRunKey)
            enableLaunchAtLoginOnFirstRun()
        }
        // Autostart is driven by the first device enumeration, not a fixed delay:
        // refresh() publishes asynchronously, so a timer could fire before the
        // defaults are known and start with no microphone (D-021).
    }

    private static let didFirstRunKey = "antibleed.didFirstRun"

    private func enableLaunchAtLoginOnFirstRun() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() } catch {
            // Not fatal: the app still runs, it just will not come back after a reboot.
            lastError = "Could not enable launch at login: \(error.localizedDescription)"
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

    /// Resolves empty selections to the current system defaults. Runs on first
    /// launch (nothing persisted yet) and again whenever a stored device is gone,
    /// so a fresh install is usable without opening any picker.
    /// Returns true when something changed.
    @discardableResult
    func adoptSystemDefaultsIfNeeded() -> Bool {
        var changed = false
        // A stale selection pointing at one of our own devices (an old capture
        // aggregate UID that no longer exists, or the virtual mic itself) would
        // fail forever with "not found". Drop it and re-resolve (D-022).
        if selectedMicUID.hasPrefix(DeviceManager.ownDeviceUIDPrefix) {
            selectedMicUID = ""
            changed = true
        }
        if selectedOutputUID.hasPrefix(DeviceManager.ownDeviceUIDPrefix) {
            selectedOutputUID = ""
            changed = true
        }
        if selectedMicUID.isEmpty, let def = deviceManager.defaultInputUID, !def.isEmpty {
            selectedMicUID = def
            changed = true
        }
        if selectedOutputUID.isEmpty, let def = deviceManager.defaultOutputUID, !def.isEmpty {
            selectedOutputUID = def
            changed = true
        }
        return changed
    }

    func startIfPossible() {
        adoptSystemDefaultsIfNeeded()
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

    /// Installs the driver bundled in the app and restarts the pipeline once
    /// Core Audio has published the new devices (D-023).
    func installDriver() {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        lastError = nil
        Task { @MainActor in
            defer { isInstallingDriver = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller.install()
                }.value
            } catch {
                lastError = error.localizedDescription
                driverStatus = DriverInstaller.status()
                return
            }
            // coreaudiod needs a moment to republish the device list.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            deviceManager.refresh()
            driverStatus = DriverInstaller.status()
            // Pick up the now-present writer: without a restart the pipeline keeps
            // running with no destination for the cleaned audio.
            if isRunning { restart() }
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
        // Fresh install: nothing persisted, so adopt whatever macOS is using.
        adoptSystemDefaultsIfNeeded()
        driverStatus = DriverInstaller.status()
        // Autostart fires here rather than on a timer, because this is the first
        // point at which the device list (and therefore the defaults) is known.
        if autoStart && !isRunning && !hasAutoStarted && !selectedMicUID.isEmpty {
            hasAutoStarted = true
            startIfPossible()
            return  // start() already calls syncOutputRoutePause()
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
