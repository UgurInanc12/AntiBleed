import Foundation
import Combine

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Phase 1: AVAudioEngine-based capture (AUHAL-ready).
/// Real-time callback pushes timestamped blocks into a ring; DSP thread assembles 480-sample frames.
final class MicrophoneCapture: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var currentSampleRate: Double = AudioConstants.sampleRate

    var onFrames: (([AudioFrame]) -> Void)?

    private var sequence: UInt64 = 0

#if canImport(AVFoundation)
    private var engine: AVAudioEngine?

    func start(deviceUID: String?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // CRITICAL: disable Voice Processing (PLAN 10.1)
        if #available(macOS 13.0, *) {
            try? inputNode.setVoiceProcessingEnabled(false)
            assert(inputNode.voiceProcessingEnabled == false, "Voice Processing must be OFF")
        }

        // Select device by UID if provided (via HAL AudioUnit property)
        // Format handling: capture at device native format, convert downstream

        let hwFormat = inputNode.outputFormat(forBus: 0)
        currentSampleRate = hwFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
            guard let self else { return }
            // Real-time safe: copy, timestamp, push - no allocation beyond preallocated staging
            // For Phase 0-1 stub: just count
            self.sequence += 1
            // In real impl: copy buffer.floatChannelData, attach hostTime/sampleTime, push to RawMicRing
            _ = time.hostTime
        }

        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }
#else
    func start(deviceUID: String?) throws {
        // Windows/CI stub
        isRunning = true
    }
    func stop() { isRunning = false }
#endif
}
