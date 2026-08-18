import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    row("Selected microphone", appState.diagnostics.selectedMicName)
                    row("Selected output", appState.diagnostics.selectedOutputName)
                    row("Tap status", appState.diagnostics.tapStatus)
                    row("Driver", appState.diagnostics.driverVersion)
                }
                Divider()
                Group {
                    row("Sample rates", appState.diagnostics.sampleRates)
                    row("Queue depths", appState.diagnostics.queueDepths)
                    row("Overruns", "\(appState.diagnostics.overruns)")
                    row("Underruns", "\(appState.diagnostics.underruns)")
                }
                Divider()
                Group {
                    row("AEC state", appState.pipelineState.rawValue)
                    row("AEC delay", appState.aecStats.delayMs >= 0 ? "\(appState.aecStats.delayMs) ms" : "-")
                    row("ERL / ERLE", String(format: "%.1f / %.1f dB", appState.aecStats.echoReturnLoss, appState.aecStats.echoReturnLossEnhancement))
                    row("Divergent frac", String(format: "%.3f", appState.aecStats.divergentFilterFraction))
                }
                Divider()
                row("Permissions mic", appState.permissions.mic.rawValue)
                row("Permissions tap", appState.permissions.systemAudio.rawValue)
            }
            .font(.caption).monospaced()
            .padding()
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}
