import SwiftUI
import AntiBleedAudio

@available(macOS 14.2, *)
struct DeviceSelectorView: View {
    enum Kind { case input, output }
    var kind: Kind
    @EnvironmentObject var appState: AppState

    var body: some View {
        Picker("", selection: binding) {
            if kind == .output {
                Text("None (headphones, no cancellation)").tag("")
            }
            ForEach(devices) { dev in
                Text(dev.name).tag(dev.uid)
            }
        }
        .labelsHidden()
    }

    private var devices: [AudioDevice] {
        kind == .input ? appState.deviceManager.inputDevices : appState.deviceManager.outputDevices
    }

    private var binding: Binding<String> {
        Binding(
            get: { kind == .input ? appState.selectedMicUID : appState.selectedOutputUID },
            set: { uid in
                if kind == .input { appState.selectMic(uid) } else { appState.selectOutput(uid) }
            }
        )
    }
}
