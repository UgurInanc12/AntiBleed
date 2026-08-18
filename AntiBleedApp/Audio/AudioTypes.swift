import Foundation

/// Canonical format constants (D-007)
enum AudioConstants {
    static let sampleRate: Double = 48000
    static let frameSize: Int = 480        // 10 ms @ 48 kHz
    static let frameDurationMs: Double = 10
    static let channels: Int = 1
}

struct AudioFrame {
    var samples: [Float]   // exactly 480
    var hostTime: UInt64
    var sampleTime: Double
    var rateScalar: Double
    var sequenceNumber: UInt64
    var rmsDb: Float

    init(samples: [Float], hostTime: UInt64 = 0, sampleTime: Double = 0, rateScalar: Double = 1, sequenceNumber: UInt64 = 0) {
        self.samples = samples
        self.hostTime = hostTime
        self.sampleTime = sampleTime
        self.rateScalar = rateScalar
        self.sequenceNumber = sequenceNumber
        // RMS
        if samples.isEmpty { self.rmsDb = -.infinity }
        else {
            let sum = samples.reduce(0.0) { $0 + Double($1 * $1) }
            let r = sqrt(sum / Double(samples.count))
            self.rmsDb = r < 1e-9 ? -.infinity : Float(20 * log10(r))
        }
    }

    static func silence(sequenceNumber: UInt64 = 0) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: 0, count: AudioConstants.frameSize), sequenceNumber: sequenceNumber)
    }
}

enum AudioSource { case mic, render }
