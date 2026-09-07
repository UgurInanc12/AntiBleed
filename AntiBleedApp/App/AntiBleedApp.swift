import SwiftUI

@available(macOS 14.2, *)
@main
struct AntiBleedApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRunning ? "waveform.badge.mic" : "mic.slash")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        Window("Anti-Bleed Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(appState)
        }
        .defaultSize(width: 460, height: 520)
    }
}
