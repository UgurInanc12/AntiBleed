import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement
import AntiBleedCore
import AntiBleedAudio

@available(macOS 14.2, *)
extension AppState {
    func setupDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        diagnosticLog.record("session_start", fields: [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": info["CFBundleVersion"] as? String ?? "unknown",
            "revision": info["AntiBleedBuildRevision"] as? String ?? "unpackaged",
            "build_time": info["AntiBleedBuildTime"] as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": pipeline.currentSnapshot().engineName,
            "bundled_driver_version": DriverInstaller.bundledDriverPath.flatMap { DriverInstaller.version(ofDriverAt: $0) } ?? "missing",
            "installed_driver_version": DriverInstaller.version(ofDriverAt: DriverInstaller.installedPath) ?? "missing",
            "audio_recorded": "false", "summary_interval_seconds": "1",
            "max_file_bytes": "5242880", "max_files": "20"
        ])
        pipeline.onDiagnosticTransition = { [weak self] fields in
            self?.diagnosticLog.record("state_transition", fields: fields)
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.diagnosticLog.record("health_partial", fields: self.diagnosticHealth.finish())
                self.logEvent("session_end")
                self.diagnosticLog.flush()
            }.store(in: &diagnosticObservers)
        for (notification, event) in [(NSWorkspace.willSleepNotification, "system_sleep"),
                                       (NSWorkspace.didWakeNotification, "system_wake")] {
            NSWorkspace.shared.notificationCenter.publisher(for: notification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.logEvent(event) }
                .store(in: &diagnosticObservers)
        }
    }

    func diagnosticContext() -> [String: String] {
        ["running": String(isRunning), "state": pipelineState.rawValue,
         "revision": Bundle.main.infoDictionary?["AntiBleedBuildRevision"] as? String ?? "unpackaged",
         "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
         "capture": snapshot.captureState, "writer": snapshot.writerState,
         "output": snapshot.engine.output, "aec_enabled": String(isAECEnabled),
         "route_bypass": String(isPausedForOutputRoute),
         "bypass_on_other_output": String(pauseWhenOutputNotDefault),
         "auto_start": String(autoStart),
         "system_output_name": deviceManager.device(uid: deviceManager.defaultOutputUID)?.name ?? "none",
         "system_output_id": deviceManager.device(uid: deviceManager.defaultOutputUID).map { String($0.id) } ?? "none",
         "input_device_count": String(deviceManager.inputDevices.count),
         "output_device_count": String(deviceManager.outputDevices.count),
         "mic_name": selectedMic?.name ?? "none", "output_name": selectedOutput?.name ?? "none",
         // Do not store serial-bearing hardware UIDs. HAL IDs are session-local.
         "mic_id": selectedMic.map { String($0.id) } ?? "none",
         "output_id": selectedOutput.map { String($0.id) } ?? "none",
         "mic_rate": selectedMic.map { String($0.sampleRate) } ?? "unknown",
         "output_rate": selectedOutput.map { String($0.sampleRate) } ?? "unknown",
         "reference_is_default": String(referenceOutputIsDefault),
         "driver_present": String(driverInstalled), "driver_status": String(describing: driverStatus),
         "mic_permission": permissions.mic.rawValue, "system_audio_permission": permissions.systemAudio.rawValue]
    }

    func logEvent(_ event: String) {
        diagnosticLog.record(event, fields: diagnosticContext())
    }

    func observeDiagnostics() {
        let currentStatus = diagnosticLog.status
        if logStatus != currentStatus { logStatus = currentStatus }
        guard loggingEnabled else { return }
        let context = diagnosticContext()
        if context != lastDiagnosticContext {
            diagnosticLog.record("configuration_changed", fields: context)
            lastDiagnosticContext = context
        }
        let e = snapshot.engine
        diagnosticHealth.observe(metrics: [
            "raw_db": Double(e.rawMicRmsDb), "render_db": Double(e.renderRmsDb),
            "clean_db": Double(e.cleanedRmsDb), "coupling": Double(e.couplingScore),
            "correlation": Double(e.couplingCorrelation), "aec_delay_ms": Double(e.aec.delayMs),
            "erle_db": Double(e.aec.echoReturnLossEnhancement),
            "divergence": Double(e.aec.divergentFilterFraction),
            "residual_echo": Double(e.aec.residualEchoLikelihood),
            "skew_ms": e.sync.bufferSkewMs, "capture_rate": snapshot.captureSampleRate,
            "path_alignment_samples": Double(e.pathAlignmentSamples)
        ], counters: [
            "frames": e.framesProcessed, "transitions": e.transitions,
            "capture_overruns": snapshot.captureRingOverruns,
            "writer_underruns": snapshot.writerUnderruns, "writer_overruns": snapshot.writerOverruns,
            "sync_underruns": e.sync.underruns, "sync_overruns": e.sync.overruns,
            "stale_mic": e.sync.staleDropsMic, "stale_render": e.sync.staleDropsRender
        ])
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHealthTime >= 1 else { return }
        var fields = diagnosticHealth.finish()
        fields.merge(context) { _, new in new }
        fields["window_seconds"] = String(now - lastHealthTime)
        fields["aec_stats_valid"] = String(e.aec.valid)
        fields["processing_stalled"] = String(isRunning && fields["frames.delta"] == "0")
        diagnosticLog.record("health_summary", fields: fields)
        lastHealthTime = now
    }

    func setDiagnosticLogging(_ enabled: Bool) {
        diagnosticLog.setEnabled(enabled)
        diagnosticHealth = DiagnosticHealthWindow()
        lastHealthTime = ProcessInfo.processInfo.systemUptime
        lastDiagnosticContext = [:]
        let currentStatus = diagnosticLog.status
        if logStatus != currentStatus { logStatus = currentStatus }
        if enabled {
            logEvent("logging_context")
            let info = Bundle.main.infoDictionary ?? [:]
            diagnosticLog.record("build_context", fields: [
                "revision": info["AntiBleedBuildRevision"] as? String ?? "unpackaged",
                "build_time": info["AntiBleedBuildTime"] as? String ?? "unknown",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "engine": pipeline.currentSnapshot().engineName,
                "installed_driver_version": DriverInstaller.version(ofDriverAt: DriverInstaller.installedPath) ?? "missing"
            ])
        }
    }

    func markDiagnosticProblem() {
        guard loggingEnabled else { return }
        logEvent("problem_marker")
        observeDiagnostics()
        logNotice = "Problem marked at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))."
    }

    func exportDiagnosticLogs() {
        guard !isExportingLogs else { return }
        isExportingLogs = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "AntiBleed-\(diagnosticLog.sessionID.prefix(8)).zip"
        panel.title = "Export diagnostic logs (no audio)"
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                self.isExportingLogs = false
                return
            }
            self.logNotice = nil
            self.logEvent("export_requested")
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("AntiBleed-export-\(UUID().uuidString)")
            self.diagnosticLog.exportSnapshot(to: staging) { result in
                // Leave the log writer free while compression runs.
                DispatchQueue.global(qos: .utility).async {
                    let archive = staging.appendingPathExtension("zip")
                    defer {
                        try? FileManager.default.removeItem(at: staging)
                        try? FileManager.default.removeItem(at: archive)
                    }
                    let outcome: Result<Void, Error>
                    do {
                        _ = try result.get()
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        process.arguments = ["-c", "-k", "--keepParent", staging.path, archive.path]
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                        // Atomic replacement after compression succeeds, including across volumes.
                        try Data(contentsOf: archive).write(to: destination, options: .atomic)
                        outcome = .success(())
                    } catch { outcome = .failure(error) }
                    DispatchQueue.main.async {
                        self.isExportingLogs = false
                        switch outcome {
                        case .success:
                            self.logNotice = "Diagnostic ZIP exported. Review it before sharing. No audio included."
                            self.logEvent("export_completed")
                        case .failure(let error):
                            self.logNotice = "Export failed (\((error as NSError).domain):\((error as NSError).code))."
                            self.diagnosticLog.record("export_failed", fields: ["code": String((error as NSError).code)])
                        }
                    }
                }
            }
        }
    }
}
