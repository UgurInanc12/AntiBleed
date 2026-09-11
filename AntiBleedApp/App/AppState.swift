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
    @Published var lastError: String? {
        didSet {
            if let lastError, lastError != oldValue { diagnosticLog.record("app_error", fields: ["message": lastError]) }
        }
    }
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

    @AppStorage("antibleed.loggingEnabled") var loggingEnabled = true
    @Published var logStatus = DiagnosticLog.Status()
    @Published var isExportingLogs = false
    @Published var logNotice: String?
    let diagnosticLog = DiagnosticLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AntiBleed"),
        enabled: UserDefaults.standard.object(forKey: "antibleed.loggingEnabled") as? Bool ?? true)
    var diagnosticHealth = DiagnosticHealthWindow()
    var lastHealthTime = ProcessInfo.processInfo.systemUptime
    var lastDiagnosticContext: [String: String] = [:]
    var diagnosticObservers: [AnyCancellable] = []

    private var timer: AnyCancellable?
    /// Autostart must fire exactly once per launch, not on every device change.
    private var hasAutoStarted = false
    /// Tracks the writer so its appearance (driver installed while running) can
    /// trigger exactly one restart (D-023).
    private var hadWriter = false
    private var startTask: Task<Void, Never>?
    private var resumeWhenDevicesReturn = false

    init() {
        isAECEnabled = UserDefaults.standard.object(forKey: "antibleed.aecEnabled") as? Bool ?? true
        setupDiagnostics()
        deviceManager.onDevicesChanged = { [weak self] in self?.handleDevicesChanged() }
        deviceManager.observeDeviceChanges()
        deviceManager.refresh()
        permissions.refreshMicStatus()

        pipeline.onStateChange = { [weak self] from, to in
            guard let self else { return }
            if self.pipelineState != .error { self.pipelineState = to }
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.recentTransitions.insert("\(stamp)  \(from.rawValue) -> \(to.rawValue)", at: 0)
            if self.recentTransitions.count > 50 { self.recentTransitions.removeLast() }
        }
        pipeline.onError = { [weak self] msg in self?.lastError = msg }

        timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            if self.isRunning {
                self.snapshot = self.pipeline.currentSnapshot()
                self.pipelineState = self.snapshot.engine.state
            }
            self.observeDiagnostics()
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
        if isInstallingDriver { return "Installing virtual microphone" }
        if pipelineState == .error { return "Error" }
        if !isRunning { return "Stopped" }
        if snapshot.writerState != "running" { return "Diagnostics only: virtual microphone unavailable" }
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
        guard !isInstallingDriver, startTask == nil else { return }
        logEvent("start_requested")
        permissions.refreshMicStatus()
        if permissions.mic == .notDetermined {
            startTask = Task { @MainActor in
                let s = await permissions.requestMic()
                diagnosticLog.record("microphone_permission", fields: ["result": s.rawValue])
                guard !Task.isCancelled else { return }
                startTask = nil
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
            snapshot = pipeline.currentSnapshot()
            pipelineState = snapshot.engine.state
            lastError = snapshot.lastError
            if !selectedOutputUID.isEmpty {
                permissions.recordSystemAudioOutcome(granted: pipeline.capture.state == .running)
            }
            // Starting while the system already plays through something else must
            // come up in raw-mic mode, not with the AEC engaged (D-020).
            syncOutputRoutePause()
            logEvent("start_succeeded")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            pipelineState = .error
            logEvent("start_failed")
        }
    }

    /// Installs the driver bundled in the app and restarts the pipeline once
    /// Core Audio has published the new devices (D-023).
    func installDriver() {
        logEvent("install_requested")
        guard !isInstallingDriver else { return }
        let shouldResume = isRunning || autoStart
        guard stop() else { return }
        isInstallingDriver = true
        lastError = nil
        Task { @MainActor in
            defer { isInstallingDriver = false }
            do {
                // NSAppleScript must stay on the main thread.
                try DriverInstaller.install()
                logEvent("install_copy_completed")
            } catch {
                isInstallingDriver = false
                if shouldResume { startIfPossible() }
                lastError = error.localizedDescription
                driverStatus = DriverInstaller.status()
                logEvent("install_failed")
                return
            }
            // Wait for HAL publication, rather than treating a successful copy as readiness.
            for _ in 0..<20 {
                deviceManager.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if driverInstalled && selectedMic != nil { break }
            }
            driverStatus = DriverInstaller.status()
            isInstallingDriver = false
            guard driverInstalled else {
                lastError = "Driver copied, but Core Audio has not published the virtual microphone. Restart macOS, then try again."
                return
            }
            logEvent("install_devices_ready")
            hadWriter = true
            if shouldResume { startIfPossible() }
        }
    }
    @discardableResult
    func stop() -> Bool {
        observeDiagnostics()
        if loggingEnabled { diagnosticLog.record("health_partial", fields: diagnosticHealth.finish()) }
        logEvent("stop_requested")
        startTask?.cancel()
        startTask = nil
        hasAutoStarted = true
        resumeWhenDevicesReturn = false
        guard pipeline.stop() else {
            lastError = pipeline.currentSnapshot().lastError
            pipelineState = .error
            logEvent("stop_timeout")
            return false
        }
        isRunning = false
        pipelineState = .stopped
        // Nothing is running, so the route flag no longer describes anything.
        isPausedForOutputRoute = false
        snapshot = pipeline.currentSnapshot()
        logEvent("stop_completed")
        return true
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
        logEvent("restart_requested")
        // start() re-evaluates the route flag through syncOutputRoutePause().
        guard stop() else { return }
        start()
    }

    private func handleDevicesChanged() {
        logEvent("devices_changed")
        guard !isInstallingDriver else { return }
        let previousMic = selectedMicUID
        let previousOutput = selectedOutputUID
        if !selectedMicUID.isEmpty, selectedMic == nil {
            selectedMicUID = deviceManager.defaultInputUID ?? ""
        }
        if !selectedOutputUID.isEmpty, selectedOutput == nil {
            selectedOutputUID = deviceManager.defaultOutputUID ?? ""
        }
        adoptSystemDefaultsIfNeeded()
        driverStatus = DriverInstaller.status()
        let selectionChanged = previousMic != selectedMicUID || previousOutput != selectedOutputUID
        let writerPresent = deviceManager.virtualWriterPresent
        let writerChanged = writerPresent != hadWriter
        hadWriter = writerPresent

        if isRunning && selectedMicUID.isEmpty {
            let stopped = stop()
            resumeWhenDevicesReturn = stopped
            lastError = "No microphone available. Waiting for a device."
            return
        }
        if isRunning && (selectionChanged || writerChanged) {
            restart()
            return
        }
        if !isRunning && !selectedMicUID.isEmpty &&
            (resumeWhenDevicesReturn || (autoStart && !hasAutoStarted)) {
            resumeWhenDevicesReturn = false
            hasAutoStarted = true
            startIfPossible()
            return
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
    func syncOutputRoutePause() {
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

        } else if onReference && isPausedForOutputRoute {
            isPausedForOutputRoute = false
        }
    }
}
