import Foundation
import Combine

/// Phase 2: Core Audio Process Tap (CATapDescription).
/// Provides the far-end render reference for AEC.
final class SystemAudioTap: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var tapStatus: String = "NotCreated"
    @Published var renderRmsDb: Float = -.infinity

    var onRenderFrames: (([AudioFrame]) -> Void)?

#if canImport(CoreAudio)
    private var tapID: UInt32 = 0
    private var aggregateID: UInt32?

    func createTap(for outputDeviceUID: String) throws {
        // Use CATapDescription + AudioHardwareCreateProcessTap
        // Private, unmuted, exclude own process and Anti-Bleed_internal_writer
        // See Apple sample: CaptureSystemAudioWithTaps
        tapStatus = "Creating"
        // Stub: real impl on Mac
        tapStatus = "Running"
        isRunning = true
    }

    func start() throws {
        tapStatus = "Running"
        isRunning = true
    }

    func stop() {
        tapStatus = "Stopped"
        isRunning = false
    }

    func destroy() {
        // AudioHardwareDestroyProcessTap(tapID)
        tapID = 0
        tapStatus = "NotCreated"
        isRunning = false
    }
#else
    func createTap(for outputDeviceUID: String) throws {
        tapStatus = "Running (stub - no Core Audio on this OS)"
        isRunning = true
    }
    func start() throws { isRunning = true; tapStatus = "Running" }
    func stop() { isRunning = false; tapStatus = "Stopped" }
    func destroy() { isRunning = false; tapStatus = "NotCreated" }
#endif
}
