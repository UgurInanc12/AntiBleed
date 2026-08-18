import SwiftUI

struct DeviceSelectorView: View {
    enum Kind { case input, output }
    var kind: Kind
    @EnvironmentObject var appState: AppState

    var body: some View {
        Picker(kind == .input ? "Microphone" : "Output", selection: kind == .input ? $appState.selectedMicUID : $appState.selectedOutputUID) {
            ForEach(devices, id: \.self) { uid in
                Text(uid).tag(Optional(uid))
            }
        }
        .labelsHidden()
    }

    private var devices: [String] {
        if kind == .input {
            return appState.deviceManager.inputDevices.map { $0.uid }
        } else {
            return appState.deviceManager.outputDevices.map { $0.uid }
        }
    }
}
