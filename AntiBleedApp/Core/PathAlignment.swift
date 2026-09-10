import Foundation

/// Fixed sample delay applied to the raw microphone path (PLAN 13.8, D-008).
///
/// The AEC output lags its own input by a constant number of samples (the APM's
/// internal processing latency, measured at ~430 samples / 9 ms at 48 kHz).
/// Exposing the undelayed raw mic in BYPASS and the AEC output in ACTIVE would
/// therefore splice two different instants together on every transition: the
/// stream jumps forward or backward by that latency and the user hears a skip,
/// and the crossfade mixes a signal with a time-shifted copy of itself.
///
/// Delaying the raw path by exactly the AEC latency makes both candidate outputs
/// describe the same instant, so a switch is a pure gain change.
public struct DelayLine {
    public private(set) var delaySamples: Int
    private var buffer: [Float]
    private var index: Int = 0

    public init(delaySamples: Int = 0) {
        self.delaySamples = max(0, delaySamples)
        buffer = [Float](repeating: 0, count: max(0, delaySamples))
    }

    /// Returns `input` delayed by `delaySamples`. Length is preserved.
    public mutating func process(_ input: [Float]) -> [Float] {
        guard delaySamples > 0 else { return input }
        var out = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            out[i] = buffer[index]
            buffer[index] = input[i]
            index += 1
            if index >= buffer.count { index = 0 }
        }
        return out
    }

    public mutating func reset() {
        for i in 0..<buffer.count { buffer[i] = 0 }
        index = 0
    }

    /// Changes the delay and clears the history (route change / recalibration).
    public mutating func setDelay(_ samples: Int) {
        delaySamples = max(0, samples)
        buffer = [Float](repeating: 0, count: delaySamples)
        index = 0
    }
}

/// Measures an echo canceller's own input-to-output latency so the raw path can
/// be aligned to it instead of hard-coding a number that changes with the engine
/// build or the sample rate.
public enum EchoCancellerLatency {
    /// Pushes a short deterministic calibration burst (render silent, capture
    /// noise) through the canceller and correlates input against output.
    /// The canceller is reset afterwards, so no calibration state survives into
    /// the live stream. Returns 0 when the measurement is not trustworthy.
    public static func measure(_ aec: EchoCanceller,
                               frameSize: Int = AudioConstants.frameSize,
                               frames: Int = 10,
                               maxLagSamples: Int = 1440,
                               minCorrelation: Float = 0.5) -> Int {
        guard aec.isRealAEC, frameSize > 0, frames > 0 else { return 0 }

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextSample() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let unit = Float(state >> 40) / Float(1 << 24)   // 0..1
            return (unit - 0.5) * 0.1
        }

        let silence = [Float](repeating: 0, count: frameSize)
        var input: [Float] = []
        var output: [Float] = []
        input.reserveCapacity(frameSize * frames)
        output.reserveCapacity(frameSize * frames)

        for _ in 0..<frames {
            var capture = [Float](repeating: 0, count: frameSize)
            for i in 0..<frameSize { capture[i] = nextSample() }
            aec.processRender(silence)
            let produced = aec.processCapture(capture)
            guard produced.count == frameSize else { aec.reset(); return 0 }
            input.append(contentsOf: capture)
            output.append(contentsOf: produced)
        }
        aec.reset()

        let lagCap = min(maxLagSamples, input.count - frameSize)
        guard lagCap > 0 else { return 0 }
        let n = input.count - lagCap
        guard n > 0 else { return 0 }

        var best: Float = 0
        var bestLag = 0
        input.withUnsafeBufferPointer { ip in
            output.withUnsafeBufferPointer { op in
                for lag in 0...lagCap {
                    var dot = 0.0, energyIn = 0.0, energyOut = 0.0
                    for i in 0..<n {
                        let a = Double(ip[i]), b = Double(op[i + lag])
                        dot += a * b; energyIn += a * a; energyOut += b * b
                    }
                    let denom = (energyIn * energyOut).squareRoot()
                    if denom > 1e-12 {
                        let c = Float(dot / denom)
                        if abs(c) > abs(best) { best = c; bestLag = lag }
                    }
                }
            }
        }
        return abs(best) >= minCorrelation ? bestLag : 0
    }
}
