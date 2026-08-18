import Foundation

/// Phase 6: BlackHole variant. Phase 8: native AntiBleed.driver writer.
final class VirtualMicWriter {
    enum WriterKind { case blackHole, native }
    var kind: WriterKind = .native
    private var isRunning = false

    func resolveWriter() throws {
#if canImport(CoreAudio)
        // Find by UID: com.antibleed.writer (native) or BlackHole2ch_UID (Phase 6)
        // Verify kAudioDevicePropertyIsHidden for native writer
#endif
    }

    func startWriting(sampleRate: Double = AudioConstants.sampleRate) throws {
        isRunning = true
    }

    func write(frames: [AudioFrame]) {
        guard isRunning else { return }
        // Write via HAL output to hidden writer
        // On underflow: app stops writing, driver outputs silence
    }

    func stop() { isRunning = false }
    var isResolved: Bool { isRunning }
}
