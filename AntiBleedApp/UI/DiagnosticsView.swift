import SwiftUI
import AntiBleedCore
import AntiBleedAudio

@available(macOS 14.2, *)
struct DiagnosticsView: View {
    @EnvironmentObject var appState: AppState

    private var s: AntiBleedPipeline.Snapshot { appState.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    row("Engine", s.engineName)
                    row("Pipeline", appState.isRunning ? "running" : "stopped")
                    row("State", s.engine.state.rawValue)
                    row("Output", s.engine.output)
                    row("Microphone", appState.selectedMic?.name ?? "-")
                    row("Speakers", appState.selectedOutput?.name ?? "none")
                    row("Capture", s.captureState)
                    row("Capture rate", s.captureSampleRate > 0 ? String(format: "%.0f Hz", s.captureSampleRate) : "-")
                    row("Writer", s.writerState)
                    row("Driver", appState.driverInstalled ? "installed" : "missing")
                }
                Divider()
                Group {
                    row("Coupling score", String(format: "%.2f", s.engine.couplingScore))
                    row("Coupling corr", String(format: "%.2f", s.engine.couplingCorrelation))
                    row("AEC delay", s.engine.aec.valid && s.engine.aec.delayMs >= 0 ? "\(s.engine.aec.delayMs) ms" : "-")
                    row("ERL / ERLE", String(format: "%.1f / %.1f dB", s.engine.aec.echoReturnLoss, s.engine.aec.echoReturnLossEnhancement))
                    row("Divergent fraction", String(format: "%.3f", s.engine.aec.divergentFilterFraction))
                    row("Residual echo", String(format: "%.2f", s.engine.aec.residualEchoLikelihood))
                    row("Path alignment", s.engine.pathAlignmentSamples > 0
                        ? String(format: "%d samples (%.2f ms)", s.engine.pathAlignmentSamples,
                                 Double(s.engine.pathAlignmentSamples) / AudioConstants.sampleRate * 1000)
                        : "none (no real AEC)")
                }
                Divider()
                Group {
                    row("Sync skew", String(format: "%.2f ms (max %.2f)", s.engine.sync.bufferSkewMs, s.engine.sync.skewAbsMaxMs))
                    row("Queue depth", "render \(s.engine.sync.renderDepth) / mic \(s.engine.sync.micDepth)")
                    row("Sync underruns", "\(s.engine.sync.underruns)")
                    row("Stale drops", "render \(s.engine.sync.staleDropsRender) / mic \(s.engine.sync.staleDropsMic)")
                    row("Capture overruns", "\(s.captureRingOverruns)")
                    row("Writer under/over", "\(s.writerUnderruns) / \(s.writerOverruns)")
                    row("Frames", "\(s.engine.framesProcessed)")
                    row("Transitions", "\(s.engine.transitions)")
                }
                Divider()
                row("Mic permission", appState.permissions.mic.rawValue)
                row("System audio", appState.permissions.systemAudio.rawValue)
                if let err = s.lastError { row("Last error", err) }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Diagnostic logging (no audio)", isOn: $appState.loggingEnabled)
                        .onChange(of: appState.loggingEnabled) { _, enabled in appState.setDiagnosticLogging(enabled) }
                    Text("Local only. Up to 20 files of 5 MiB; oldest files are removed.")
                        .foregroundStyle(.secondary)
                    row("Log records / dropped", "\(appState.logStatus.written) / \(appState.logStatus.dropped)")
                    row("Old log files removed", "\(appState.logStatus.prunedFiles)")
                    if let error = appState.logStatus.error { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Mark a problem") { appState.markDiagnosticProblem() }
                            .disabled(!appState.loggingEnabled)
                        Button(appState.isExportingLogs ? "Exporting..." : "Export diagnostic logs") {
                            appState.exportDiagnosticLogs()
                        }.disabled(appState.isExportingLogs)
                    }
                    if let notice = appState.logNotice { Text(notice).textSelection(.enabled) }
                }
                Divider()
                Text("Recent transitions").font(.caption).foregroundStyle(.secondary)
                ForEach(appState.recentTransitions.prefix(12), id: \.self) { Text($0) }
            }
            .font(.caption).monospaced()
            .padding()
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
    }
}
