import Foundation

/// Pure signal metrics used by the coupling detector, meters and tests.
/// Mirrors DSP/SignalMetrics.cpp and Tests/dsp/signal_metrics.py.
public enum SignalMetrics {
    public static func rms(_ x: [Float]) -> Float {
        if x.isEmpty { return 0 }
        var sum: Double = 0
        for v in x { sum += Double(v) * Double(v) }
        return Float((sum / Double(x.count)).squareRoot())
    }

    public static func rmsDb(_ x: [Float]) -> Float {
        let r = rms(x)
        return r < 1e-9 ? -.infinity : 20 * log10(r)
    }

    public static func peak(_ x: [Float]) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    /// Normalized cross-correlation of a[i] with b[i+lag]. Range -1...1.
    public static func normalizedCorrelation(_ a: [Float], _ b: [Float], lag: Int) -> Float {
        let n = min(a.count, b.count)
        if n == 0 { return 0 }
        let start = lag >= 0 ? 0 : -lag
        let end = lag >= 0 ? (n > lag ? n - lag : 0) : n
        if end <= start { return 0 }
        var sa: Double = 0, sb: Double = 0, sab: Double = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in start..<end {
                    let av = Double(pa[i]), bv = Double(pb[i + lag])
                    sa += av * av; sb += bv * bv; sab += av * bv
                }
            }
        }
        let denom = (sa * sb).squareRoot()
        return denom < 1e-12 ? 0 : Float(sab / denom)
    }

    public struct CorrelationResult: Equatable {
        public var peakCorrelation: Float
        public var peakLag: Int
    }

    /// Peak |correlation| over -maxLag...maxLag.
    /// `step` > 1 trades resolution for CPU on the real-time DSP thread.
    public static func maxCorrelation(_ render: [Float], _ mic: [Float], maxLag: Int, step: Int = 1) -> CorrelationResult {
        var best = CorrelationResult(peakCorrelation: 0, peakLag: 0)
        var lag = -maxLag
        while lag <= maxLag {
            let c = normalizedCorrelation(render, mic, lag: lag)
            if abs(c) > abs(best.peakCorrelation) { best = CorrelationResult(peakCorrelation: c, peakLag: lag) }
            lag += max(1, step)
        }
        return best
    }

    public static func echoAttenuationDb(micComponent: [Float], outputComponent: [Float]) -> Float {
        let rm = rms(micComponent), ro = rms(outputComponent)
        if rm < 1e-9 { return 0 }
        if ro < 1e-9 { return 60 }
        return 20 * log10(rm / ro)
    }
}

/// Crossfade helpers (PLAN 13.5): 50-150 ms ramps between raw and processed.
public enum Crossfade {
    public static func linear(_ a: [Float], _ b: [Float], progress: Float) -> [Float] {
        let p = min(1, max(0, progress)), inv = 1 - p
        var out = [Float](repeating: 0, count: min(a.count, b.count))
        for i in 0..<out.count { out[i] = inv * a[i] + p * b[i] }
        return out
    }

    public static func equalPower(_ a: [Float], _ b: [Float], progress: Float) -> [Float] {
        let p = min(1, max(0, progress))
        let ga = cos(p * Float.pi / 2), gb = sin(p * Float.pi / 2)
        var out = [Float](repeating: 0, count: min(a.count, b.count))
        for i in 0..<out.count { out[i] = ga * a[i] + gb * b[i] }
        return out
    }
}

/// Frame-granular crossfade progress tracker.
public struct CrossfadeRamp: Equatable {
    public private(set) var totalFrames: Int = 0
    public private(set) var currentFrame: Int = 0
    public private(set) var isActive: Bool = false
    public init() {}
    public mutating func start(frames: Int) { totalFrames = frames; currentFrame = 0; isActive = frames > 0 }
    public var progress: Float {
        if !isActive || totalFrames == 0 { return 1 }
        return min(1, max(0, Float(currentFrame) / Float(totalFrames)))
    }
    public mutating func advance() {
        guard isActive else { return }
        currentFrame += 1
        if currentFrame >= totalFrames { isActive = false }
    }
    public mutating func reset() { totalFrames = 0; currentFrame = 0; isActive = false }
}
