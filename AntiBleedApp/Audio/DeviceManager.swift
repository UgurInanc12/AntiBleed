import Foundation
import Combine

#if canImport(CoreAudio)
import CoreAudio
#endif

struct AudioDevice: Identifiable, Equatable {
    var id: UInt32
    var uid: String
    var name: String
    var isInput: Bool
    var sampleRate: Double
    var channelCount: UInt32
    var transportType: UInt32 = 0
}

final class DeviceManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputUID: String?
    @Published var selectedOutputUID: String?

    func refresh() {
#if canImport(CoreAudio)
        refreshCoreAudio()
#else
        // Windows/CI: no Core Audio, leave empty (tests mock this)
#endif
    }

    func observeDeviceChanges() {
#if canImport(CoreAudio)
        // Register for kAudioHardwarePropertyDevices and kAudioDevicePropertyDeviceIsAlive
        // via AudioObjectAddPropertyListener
#endif
    }

    var selectedInputDevice: AudioDevice? {
        guard let uid = selectedInputUID else { return nil }
        return inputDevices.first { $0.uid == uid }
    }
    var selectedOutputDevice: AudioDevice? {
        guard let uid = selectedOutputUID else { return nil }
        return outputDevices.first { $0.uid == uid }
    }

#if canImport(CoreAudio)
    private func refreshCoreAudio() {
        // Enumerate via AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)
        // Filter by kAudioDevicePropertyStreams scope input/output
        // Populate inputDevices/outputDevices
    }
#endif
}
