import Foundation

enum ClockSource { case tap, mic }

/// Phase 3: Private aggregate device (mic subdevice + tap subtap) for clock sync.
final class AggregateDeviceManager: ObservableObject {
    @Published var aggregateDeviceID: UInt32?
    @Published var clockSource: ClockSource = .tap

#if canImport(CoreAudio)
    func createAggregate(micUID: String, tapID: UInt32) throws {
        // Build dictionary with kAudioAggregateDevice* keys
        // kAudioAggregateDeviceIsPrivateKey = true
        // Add subdevice (mic) and subtap
        // AudioHardwareCreateAggregateDevice
        // Stub on Mac until real SDK wiring
        aggregateDeviceID = 9999 // placeholder
    }

    func destroy() {
        if let id = aggregateDeviceID {
            // AudioHardwareDestroyAggregateDevice(id)
            _ = id
        }
        aggregateDeviceID = nil
    }
#else
    func createAggregate(micUID: String, tapID: UInt32) throws {
        aggregateDeviceID = 9999 // stub
    }
    func destroy() { aggregateDeviceID = nil }
#endif
}
