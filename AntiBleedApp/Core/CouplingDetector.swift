import Foundation

/// Ensemble acoustic-coupling detector (PLAN 13.4).
///
/// Decides whether the selected speaker output is actually reaching the selected
/// microphone (speakers) or not (headphones). No single metric is trusted alone:
///
///  1. Cross-correlation between render and mic over a 400 ms analysis window,
///     decimated 8x (6 kHz) to keep the DSP-thread cost bounded. The lag search
///     is centred on the AEC3 delay estimate when available (+-15 ms), otherwise
///     the full 0...250 ms range is scanned at a coarser step.
///  2. Peak-lag stability across consecutive updates.
///  3. AEC3 health: ERLE (echo actually being removed) raises the score,
///     divergent filter fraction lowers it.
///
/// Mirrors Tests/dsp/coupling_detector.py; keep the two in sync.
public final class CouplingDetector {
    // Tunables (diagnostics-configurable)
    public var correlationThreshold: Float = 0.3
    public var divergenceThreshold: Float = 0.3
    public var minStableWindows: Int = 5
    public var maxDelayMs: Int = 250
    public var hintWindowMs: Int = 15
    public var analysisWindowMs: Int = 400
    public var decimation: Int = 8
    public var lagStableToleranceMs: Int = 4
    /// ERLE (dB) at which the AEC-health term saturates to 1.
    public var erleFullDb: Float = 12
    public var erleStartDb: Float = 3

    private var renderHist: [Float] = []
    private var micHist: [Float] = []
    private var stableWindows = 0
    private var lastPeakLagMs: Int = -1
    private var smoothedScore: Float = 0
    private var decimPhase = 0
    private var decimAccR: Float = 0
    private var decimAccM: Float = 0

    public init() {}

    public func reset() {
        renderHist.removeAll(keepingCapacity: true)
        micHist.removeAll(keepingCapacity: true)
        stableWindows = 0
        lastPeakLagMs = -1
        smoothedScore = 0
        decimPhase = 0; decimAccR = 0; decimAccM = 0
    }

    private var decimatedRate: Float { Float(AudioConstants.sampleRate) / Float(decimation) }
    private var historyCapacity: Int { Int(decimatedRate) * (analysisWindowMs + maxDelayMs) / 1000 }

    /// Feed one 10 ms frame pair (called every frame; cheap: box-decimation only).
    public func push(render: [Float], mic: [Float]) {
        let n = min(render.count, mic.count)
        var i = 0
        while i < n {
            decimAccR += render[i]; decimAccM += mic[i]
            decimPhase += 1
            if decimPhase == decimation {
                renderHist.append(decimAccR / Float(decimation))
                micHist.append(decimAccM / Float(decimation))
                decimPhase = 0; decimAccR = 0; decimAccM = 0
            }
            i += 1
        }
        let cap = historyCapacity
        if renderHist.count > cap {
            renderHist.removeFirst(renderHist.count - cap)
            micHist.removeFirst(micHist.count - cap)
        }
    }

    /// Runs the (heavier) analysis. Call every few frames, not every frame.
    public func evaluate(aecStats: AECStats) -> CouplingResult {
        let rate = decimatedRate
        let winLen = Int(rate) * analysisWindowMs / 1000
        let maxLag = Int(rate) * maxDelayMs / 1000
        guard renderHist.count >= winLen + 1 else {
            return CouplingResult(score: smoothedScore, delayMs: -1, correlation: 0, stableWindows: stableWindows)
        }
        // Far end effectively silent: correlation is meaningless, decay score.
        let recentRender = Array(renderHist.suffix(winLen))
        if SignalMetrics.rms(recentRender) < 1e-5 {
            smoothedScore *= 0.8
            return CouplingResult(score: smoothedScore, delayMs: -1, correlation: 0, stableWindows: stableWindows)
        }

        // Correlate mic[t] against render[t - lag] for lag in the search range.
        // mic window = the most recent winLen samples; render is read lag samples earlier.
        let micStart = micHist.count - winLen
        let available = renderHist.count - winLen // largest lag we can look back
        let lagCap = min(maxLag, available)

        var lagLo = 0, lagHi = lagCap, step = max(1, Int(rate) / 1000) // ~1 ms coarse step
        if aecStats.valid && aecStats.delayMs >= 0 {
            let centre = Int(Float(aecStats.delayMs) / 1000 * rate)
            let half = Int(Float(hintWindowMs) / 1000 * rate)
            lagLo = max(0, centre - half); lagHi = min(lagCap, centre + half); step = 1
        }

        var best: Float = 0, bestLag = 0
        var micE: Double = 0
        for k in 0..<winLen { let v = Double(micHist[micStart + k]); micE += v * v }
        if micE < 1e-12 {
            return CouplingResult(score: smoothedScore, delayMs: -1, correlation: 0, stableWindows: stableWindows)
        }
        var lag = lagLo
        while lag <= lagHi {
            let rStart = micStart - lag
            var dot: Double = 0, rE: Double = 0
            renderHist.withUnsafeBufferPointer { rp in
                micHist.withUnsafeBufferPointer { mp in
                    for k in 0..<winLen {
                        let r = Double(rp[rStart + k]), m = Double(mp[micStart + k])
                        dot += r * m; rE += r * r
                    }
                }
            }
            if rE > 1e-12 {
                let c = Float(dot / (rE * micE).squareRoot())
                if abs(c) > abs(best) { best = c; bestLag = lag }
            }
            lag += step
        }
        let peakLagMs = Int(Float(bestLag) / rate * 1000)

        // Stability of the peak lag.
        if abs(best) > correlationThreshold {
            if lastPeakLagMs >= 0 && abs(peakLagMs - lastPeakLagMs) <= lagStableToleranceMs {
                stableWindows += 1
            } else if lastPeakLagMs < 0 {
                stableWindows = max(stableWindows, 1)
            }
            lastPeakLagMs = peakLagMs
        } else if abs(best) < correlationThreshold * 0.7 {
            stableWindows = max(0, stableWindows - 1)
            if stableWindows == 0 { lastPeakLagMs = -1 }
        }

        // AEC health / evidence.
        var aecHealth: Float = 1
        if aecStats.divergentFilterFraction > divergenceThreshold { aecHealth = 0 }
        else if aecStats.divergentFilterFraction > 0.1 { aecHealth = 0.5 }
        let erleScore: Float = aecStats.valid
            ? min(1, max(0, (aecStats.echoReturnLossEnhancement - erleStartDb) / (erleFullDb - erleStartDb)))
            : 0

        let corrScore = min(1, max(0, (abs(best) - 0.2) / 0.5))
        let stabilityScore = min(1, max(0, Float(stableWindows) / Float(minStableWindows)))
        // ERLE CONFIRMS correlation, it can never replace it (D-022). When the
        // echo path disappears (headphones) AEC3 keeps reporting the last ERLE it
        // achieved: measured 37.2 dB frozen for 6+ s after the echo was gone,
        // while correlation correctly collapsed to 0.07. Ungated, that stale term
        // alone held the score at exactly 0.35 = activeExitScore, so ACTIVE could
        // never be released. Gate it on real correlation evidence.
        let erleGate = min(1, max(0, (abs(best) - correlationThreshold * 0.5) / (correlationThreshold * 0.5)))
        let raw = (corrScore * 0.45 + erleScore * erleGate * 0.35 + stabilityScore * 0.20) * (0.5 + 0.5 * aecHealth)
        smoothedScore = 0.7 * smoothedScore + 0.3 * raw

        let delayMs = (aecStats.valid && aecStats.delayMs >= 0) ? aecStats.delayMs : peakLagMs
        return CouplingResult(score: min(1, max(0, smoothedScore)),
                              delayMs: delayMs,
                              correlation: best,
                              stableWindows: stableWindows)
    }
}

/// Render-activity gate with hangover (PLAN 13.3). Prevents flapping when the
/// far end pauses between words.
public struct RenderActivityDetector {
    public var thresholdDb: Float = -55
    public var hangoverFrames: Int = 50 // 500 ms
    private var remainingHangover = 0

    public init() {}

    public mutating func update(renderRmsDb: Float) -> RenderActivity {
        if renderRmsDb > thresholdDb {
            remainingHangover = hangoverFrames
            return RenderActivity(isActive: true, rmsDb: renderRmsDb, hangoverMs: hangoverFrames * 10)
        }
        if remainingHangover > 0 {
            remainingHangover -= 1
            return RenderActivity(isActive: true, rmsDb: renderRmsDb, hangoverMs: remainingHangover * 10)
        }
        return RenderActivity(isActive: false, rmsDb: renderRmsDb, hangoverMs: 0)
    }

    public mutating func reset() { remainingHangover = 0 }
}
