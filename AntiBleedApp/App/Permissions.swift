import SwiftUI
import Combine

enum PermissionState: String {
    case notDetermined = "NotDetermined"
    case granted = "Granted"
    case denied = "Denied"
    case restricted = "Restricted"
}

final class Permissions: ObservableObject {
    @Published var mic: PermissionState = .notDetermined
    @Published var systemAudio: PermissionState = .notDetermined

    func refreshMicStatus() {
#if os(macOS)
        // Phase 1: use AVCaptureDevice or AVAudioApplication authorization
        // Stub: query actual permission via AVAudioApplication.shared.recordPermission
        mic = .notDetermined
#endif
    }

    func requestMic() async -> PermissionState {
        // Phase 1: AVAudioApplication.requestRecordPermission
        return .notDetermined
    }

    func refreshSystemAudioStatus() {
#if os(macOS)
        systemAudio = .notDetermined
#endif
    }

    func requestSystemAudio() async -> PermissionState {
        return .notDetermined
    }
}
