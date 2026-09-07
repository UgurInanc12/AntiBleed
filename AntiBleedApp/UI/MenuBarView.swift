import SwiftUI
import AntiBleedCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Anti-Bleed").font(.headline)
                Spacer()
                StateBadge(state: appState.pipelineState, running: appState.isRunning)
            }
            Text(appState.statusLine).font(.subheadline).foregroundStyle(.secondary)

            if let err = appState.lastError, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !appState.driverInstalled {
                Text("Virtual microphone driver not installed. Run Scripts/install-driver.sh.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Microphone").font(.caption).foregroundStyle(.secondary)
            DeviceSelectorView(kind: .input)

            Text("Speakers (reference)").font(.caption).foregroundStyle(.secondary)
            DeviceSelectorView(kind: .output)

            Divider()

            HStack {
                Text("Virtual microphone")
                Spacer()
                Text("Anti-Bleed_mic").font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Toggle("Echo cancellation", isOn: $appState.isAECEnabled)

            Divider()

            MeterRow(label: "Raw mic", levelDb: appState.snapshot.engine.rawMicRmsDb)
            MeterRow(label: "Speakers", levelDb: appState.snapshot.engine.renderRmsDb)
            MeterRow(label: "Clean mic", levelDb: appState.snapshot.engine.cleanedRmsDb)

            HStack(spacing: 12) {
                Label(String(format: "%.0f%% coupling", appState.snapshot.engine.couplingScore * 100), systemImage: "waveform.path")
                if appState.snapshot.engine.aec.valid && appState.snapshot.engine.aec.delayMs >= 0 {
                    Label("\(appState.snapshot.engine.aec.delayMs) ms", systemImage: "clock")
                    Label(String(format: "%.0f dB ERLE", appState.snapshot.engine.aec.echoReturnLossEnhancement), systemImage: "speaker.slash")
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(appState.isRunning ? "Stop" : "Start") {
                    if appState.isRunning { appState.stop() } else { appState.startIfPossible() }
                }
                Spacer()
                Button("Diagnostics") { openWindow(id: "diagnostics") }
                SettingsLink { Text("Settings") }
            }

            Divider()
            Button("Quit Anti-Bleed") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct StateBadge: View {
    var state: PipelineState
    var running: Bool
    var body: some View {
        Text(running ? state.rawValue : "Off")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        guard running else { return .secondary }
        switch state {
        case .active: return .green
        case .learning, .probing: return .yellow
        case .degraded, .error: return .orange
        default: return .secondary
        }
    }
}

struct MeterRow: View {
    var label: String
    var levelDb: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                let normalized = levelDb.isFinite ? max(0, min(1, (levelDb + 60) / 60)) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2).fill(levelDb > -3 ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(normalized))
                }
            }
            .frame(height: 8)
            Text(levelDb.isFinite ? String(format: "%.0f dB", levelDb) : "-inf")
                .font(.caption2).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}
