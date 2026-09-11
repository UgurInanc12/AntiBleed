import SwiftUI

/// Single window hosting Diagnostics and Settings as tabs.
///
/// The app is `LSUIElement` (no dock icon) and its only entry point is the menu
/// bar, where SwiftUI's `SettingsLink` / `openSettings()` silently fail: the
/// Settings scene has no window context to attach to, so the button looked dead.
/// `openWindow(id:)` works from a MenuBarExtra, so both panes live here.
@available(macOS 14.2, *)
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            DiagnosticsView()
                .environmentObject(appState)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            SettingsView()
                .environmentObject(appState)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(.top, 8)
        .frame(minWidth: 460, minHeight: 520)
    }
}
