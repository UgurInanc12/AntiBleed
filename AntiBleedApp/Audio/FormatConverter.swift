import Foundation

/// Phase 1-2: sample rate / channel conversion to canonical 48 kHz mono 480-frame.
final class FormatConverter {
    var targetSampleRate: Double = AudioConstants.sampleRate
    var targetChannels: Int = AudioConstants.channels

    // Persistent converter state (AVAudioConverter on macOS, stub elsewhere)
    private var pendingSamples: [Float] = []

    /// Convert variable-size input to zero or more exact 480-sample frames.
    func push(_ samples: [Float], sampleRate: Double, channels: Int) -> [AudioFrame] {
        var frames: [AudioFrame] = []
        // Channel handling: mono select or (L+R)/2 downmix
        var mono: [Float]
        if channels == 1 {
            mono = samples
        } else {
            mono = []
            mono.reserveCapacity(samples.count / channels)
            for i in stride(from: 0, to: samples.count, by: channels) {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i + c] }
                mono.append(sum / Float(channels))
            }
        }

        // Resampling stub: if sampleRate == target, passthrough; else linear (Phase 3 does real resampler)
        if abs(sampleRate - targetSampleRate) > 1 {
            // TODO: use DSP/Resampler for real 44.1->48 conversion
        }

        pendingSamples.append(contentsOf: mono)
        while pendingSamples.count >= AudioConstants.frameSize {
            let slice = Array(pendingSamples.prefix(AudioConstants.frameSize))
            pendingSamples.removeFirst(AudioConstants.frameSize)
            frames.append(AudioFrame(samples: slice))
        }
        return frames
    }

    func flush() -> [AudioFrame] { [] }
    func reset() { pendingSamples.removeAll() }
}
