import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anti-Bleed").font(.headline)
            Text("Status: \(appState.pipelineState.rawValue)")
                .font(.subheadline).foregroundStyle(.secondary)

            Divider()

            Text("Microphone").font(.caption).foregroundStyle(.secondary)
            DeviceSelectorView(kind: .input)

            Text("Output reference").font(.caption).foregroundStyle(.secondary)
            DeviceSelectorView(kind: .output)

            Divider()

            Text("Virtual microphone").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Anti-Bleed_mic")
                Spacer()
                Text(appState.pipelineState == .active ? "Ready" : appState.pipelineState.rawValue)
                    .foregroundStyle(.secondary).font(.caption)
            }

            Toggle("Echo cancellation", isOn: $appState.isAECEnabled)

            Divider()

            MeterRow(label: "Raw Mic", levelDb: appState.meters.rawMicRmsDb)
            MeterRow(label: "Speaker Ref", levelDb: appState.meters.renderRmsDb)
            MeterRow(label: "Clean Mic", levelDb: appState.meters.cleanedRmsDb)

            if appState.aecStats.delayMs >= 0 {
                Text("AEC: \(appState.pipelineState.rawValue)  Delay: \(appState.aecStats.delayMs) ms")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Test Microphone") {}
                Spacer()
                Button("Advanced Diagnostics") {}
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct MeterRow: View {
    var label: String
    var levelDb: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                let normalized = max(0, min(1, (levelDb + 60) / 60))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2).fill(levelDb > -3 ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(normalized))
                }
            }
            .frame(height: 8)
            Text(levelDb.isInfinite ? "-inf" : String(format: "%.1f dB", levelDb))
                .font(.caption2).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
}
