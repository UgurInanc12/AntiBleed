import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: .constant(false))
                Toggle("Echo cancellation enabled", isOn: $appState.isAECEnabled)
            }
            Section("About") {
                Text("Anti-Bleed_mic 0.1.0")
                Text("All processing is local. No cloud, no upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 300)
        .padding()
    }
}
