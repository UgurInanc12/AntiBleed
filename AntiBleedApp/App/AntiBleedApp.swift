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

        // No `Settings` scene: SettingsLink silently does nothing from a
        // MenuBarExtra in an LSUIElement app, which is why the old Settings
        // button appeared dead. Settings live in this window as a tab instead,
        // opened through openWindow(id:) which works from the menu bar.
        Window("Anti-Bleed", id: "diagnostics") {
            MainWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 470, height: 560)
    }
}
