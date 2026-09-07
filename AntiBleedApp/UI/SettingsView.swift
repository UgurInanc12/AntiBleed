import SwiftUI
import ServiceManagement

@available(macOS 14.2, *)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            appState.lastError = "Launch at login: \(error.localizedDescription)"
                        }
                    }
                Toggle("Start processing when the app launches", isOn: $appState.autoStart)
                Toggle("Echo cancellation enabled", isOn: $appState.isAECEnabled)
            }
            Section("Permissions") {
                HStack {
                    Text("Microphone: \(appState.permissions.mic.rawValue)")
                    Spacer()
                    Button("Open Settings") { appState.permissions.openMicrophoneSettings() }
                }
                HStack {
                    Text("System audio: \(appState.permissions.systemAudio.rawValue)")
                    Spacer()
                    Button("Open Settings") { appState.permissions.openSystemAudioSettings() }
                }
            }
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Engine", value: appState.snapshot.engineName)
                Text("All processing is local. No cloud, no upload, no recording.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
    }
}
