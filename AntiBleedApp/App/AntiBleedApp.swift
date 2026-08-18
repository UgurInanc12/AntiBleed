import SwiftUI

@main
struct AntiBleedApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Anti-Bleed", systemImage: "waveform.badge.mic") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
