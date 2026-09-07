import Foundation

/// Streaming linear-interpolation resampler with persistent phase so frame
/// boundaries never click. Quality is sufficient for the AEC *reference* path
/// (AEC3 works on 48 kHz bands and is tolerant to mild interpolation error);
/// the user's own voice goes through the mic path which already runs at the
/// device rate, converted once here as well.
public struct StreamingResampler {
    public let fromRate: Double
    public let toRate: Double
    private let step: Double // input samples per output sample
    private var phase: Double = 0
    private var history: Float = 0 // last input sample of the previous block

    public init(fromRate: Double, toRate: Double) {
        self.fromRate = fromRate
        self.toRate = toRate
        self.step = fromRate / toRate
    }

    public var isIdentity: Bool { abs(fromRate - toRate) < 0.5 }

    public mutating func reset() { phase = 0; history = 0 }

    public mutating func process(_ input: [Float]) -> [Float] {
        if input.isEmpty { return [] }
        if isIdentity { return input }
        // Virtual input: [history] + input, so index 0 = history.
        let n = input.count
        var out: [Float] = []
        out.reserveCapacity(Int(Double(n) / step) + 2)
        // phase is position within the virtual input (0 = history sample).
        while phase + 1 <= Double(n) { // need virtual index floor(phase)+1 <= n
            let idx = Int(phase)
            let frac = Float(phase - Double(idx))
            let s0 = idx == 0 ? history : input[idx - 1]
            let s1 = input[idx]  // virtual idx+1 -> input[idx]
            out.append(s0 + (s1 - s0) * frac)
            phase += step
        }
        history = input[n - 1]
        phase -= Double(n)
        return out
    }
}

/// Converts arbitrary-size, arbitrary-rate, multi-channel blocks into exact
/// 480-sample mono frames at 48 kHz and stamps each frame with an interpolated
/// host time so the synchronizer can align streams (PLAN 8, 11).
public final class FrameAssembler {
    public let targetRate: Double
    public let frameSize: Int
    private var pending: [Float] = []
    private var pendingStartNs: UInt64 = 0
    private var resampler: StreamingResampler?
    private var currentInputRate: Double = 0
    public private(set) var sequence: UInt64 = 0
    public private(set) var framesProduced: UInt64 = 0

    public init(targetRate: Double = AudioConstants.sampleRate, frameSize: Int = AudioConstants.frameSize) {
        self.targetRate = targetRate
        self.frameSize = frameSize
        pending.reserveCapacity(frameSize * 4)
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        pendingStartNs = 0
        resampler?.reset()
        sequence = 0
    }

    /// Downmixes to mono ((L+R)/n), resamples to the target rate and slices frames.
    /// `hostTimeNs` is the host time of the first sample in `samples`.
    public func push(_ samples: [Float], sampleRate: Double, channels: Int, hostTimeNs: UInt64) -> [AudioFrame] {
        guard !samples.isEmpty, channels >= 1 else { return [] }

        var mono: [Float]
        if channels == 1 {
            mono = samples
        } else {
            let frames = samples.count / channels
            mono = [Float](repeating: 0, count: frames)
            let inv = 1 / Float(channels)
            for i in 0..<frames {
                var s: Float = 0
                let base = i * channels
                for c in 0..<channels { s += samples[base + c] }
                mono[i] = s * inv
            }
        }

        if abs(sampleRate - targetRate) > 0.5 {
            if resampler == nil || currentInputRate != sampleRate {
                resampler = StreamingResampler(fromRate: sampleRate, toRate: targetRate)
                currentInputRate = sampleRate
            }
            mono = resampler!.process(mono)
        } else {
            resampler = nil
            currentInputRate = sampleRate
        }

        if pending.isEmpty {
            pendingStartNs = hostTimeNs
        }
        pending.append(contentsOf: mono)

        var out: [AudioFrame] = []
        let frameNs = UInt64(Double(frameSize) / targetRate * 1_000_000_000)
        while pending.count >= frameSize {
            let slice = Array(pending[0..<frameSize])
            pending.removeFirst(frameSize)
            out.append(AudioFrame(samples: slice,
                                  hostTimeNs: pendingStartNs,
                                  sampleTime: Double(framesProduced * UInt64(frameSize)),
                                  sequenceNumber: sequence))
            sequence += 1
            framesProduced += 1
            pendingStartNs = pendingStartNs &+ frameNs
        }
        return out
    }

    public var pendingSamples: Int { pending.count }
}
