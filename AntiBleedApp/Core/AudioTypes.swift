import Foundation

/// Canonical format constants (D-007)
public enum AudioConstants {
    public static let sampleRate: Double = 48000
    public static let frameSize: Int = 480        // 10 ms @ 48 kHz
    public static let frameDurationMs: Double = 10
    public static let channels: Int = 1
}

/// One 10 ms mono Float32 frame with Core Audio timing metadata.
public struct AudioFrame: Equatable {
    public var samples: [Float]   // exactly 480 in the canonical path
    /// mach_absolute_time of the first sample (0 when unknown).
    public var hostTime: UInt64
    /// Same instant expressed in nanoseconds on the host clock (0 when unknown).
    /// Filled by the capture layer via AudioConvertHostTimeToNanos so that the
    /// synchronizer never has to know mach timebase details.
    public var hostTimeNs: UInt64
    public var sampleTime: Double
    public var rateScalar: Double
    public var sequenceNumber: UInt64
    public var rmsDb: Float

    public init(samples: [Float],
                hostTime: UInt64 = 0,
                hostTimeNs: UInt64 = 0,
                sampleTime: Double = 0,
                rateScalar: Double = 1,
                sequenceNumber: UInt64 = 0) {
        self.samples = samples
        self.hostTime = hostTime
        self.hostTimeNs = hostTimeNs
        self.sampleTime = sampleTime
        self.rateScalar = rateScalar
        self.sequenceNumber = sequenceNumber
        self.rmsDb = AudioFrame.computeRmsDb(samples)
    }

    public static func computeRmsDb(_ samples: [Float]) -> Float {
        if samples.isEmpty { return -.infinity }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let r = (sum / Double(samples.count)).squareRoot()
        return r < 1e-9 ? -.infinity : Float(20 * log10(r))
    }

    public static func silence(sequenceNumber: UInt64 = 0, hostTimeNs: UInt64 = 0) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: 0, count: AudioConstants.frameSize),
                   hostTimeNs: hostTimeNs, sequenceNumber: sequenceNumber)
    }

    /// Duration of this frame in nanoseconds at the canonical rate.
    public var durationNs: UInt64 {
        UInt64(Double(samples.count) / AudioConstants.sampleRate * 1_000_000_000)
    }
}

public enum AudioSource { case mic, render }

/// Pipeline/FSM states (PLAN 13.2). Shared by UI and DSP layers.
public enum PipelineState: String, Equatable, CaseIterable {
    case stopped = "Stopped"
    case bypass = "Bypass"
    case probing = "Probing"
    case learning = "Learning"
    case active = "Active"
    case degraded = "Degraded"
    case error = "Error"
}

/// Which signal the virtual microphone exposes. Never an inverted render (D-008).
public enum OutputSelection: Equatable {
    case rawMic
    case aecProcessed
    case crossfade(progress: Float) // 0 = raw, 1 = processed
    case silence
}

public struct RenderActivity: Equatable {
    public var isActive: Bool
    public var rmsDb: Float
    public var hangoverMs: Int
    public init(isActive: Bool, rmsDb: Float = -.infinity, hangoverMs: Int = 0) {
        self.isActive = isActive; self.rmsDb = rmsDb; self.hangoverMs = hangoverMs
    }
}

public struct CouplingResult: Equatable {
    public var score: Float // 0..1
    public var delayMs: Int
    public var correlation: Float
    public var stableWindows: Int
    public init(score: Float = 0, delayMs: Int = -1, correlation: Float = 0, stableWindows: Int = 0) {
        self.score = score; self.delayMs = delayMs; self.correlation = correlation; self.stableWindows = stableWindows
    }
}

/// Mirror of AECBridge/AECProcessor.hpp AECStats.
public struct AECStats: Equatable {
    public var delayMs: Int = -1
    public var delayMedianMs: Int = -1
    public var delayStddevMs: Float = -1
    public var echoReturnLoss: Float = 0
    public var echoReturnLossEnhancement: Float = 0
    public var divergentFilterFraction: Float = 0
    public var residualEchoLikelihood: Float = 0
    public var valid: Bool = false
    public init() {}
    public init(delayMs: Int, delayMedianMs: Int = -1, delayStddevMs: Float = -1,
                echoReturnLoss: Float = 0, echoReturnLossEnhancement: Float = 0,
                divergentFilterFraction: Float = 0, residualEchoLikelihood: Float = 0, valid: Bool = true) {
        self.delayMs = delayMs; self.delayMedianMs = delayMedianMs; self.delayStddevMs = delayStddevMs
        self.echoReturnLoss = echoReturnLoss; self.echoReturnLossEnhancement = echoReturnLossEnhancement
        self.divergentFilterFraction = divergentFilterFraction; self.residualEchoLikelihood = residualEchoLikelihood
        self.valid = valid
    }
}
