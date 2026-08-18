#include "CouplingDetector.hpp"
#include <algorithm>
#include <cmath>

namespace dsp {

CouplingDetector::CouplingDetector() = default;

void CouplingDetector::reset() {
    stableWindows_ = 0;
    lastPeakLag_ = 0;
    smoothedScore_ = 0.0f;
}

CouplingResult CouplingDetector::update(const float* render, const float* mic, size_t count,
                                        const AECStats& aecStats, int maxLagSamples) {
    CouplingResult result{};
    if (!render || !mic || count == 0) return result;

    // 1. Correlation/coherence
    auto corr = maxCorrelation(render, mic, count, maxLagSamples);
    result.correlation = corr.peakCorrelation;

    // 2. Delay stability
    bool delayStable = false;
    if (aecStats.delayMs >= 0 && aecStats.delayStddevMs < 5.0f) {
        delayStable = (std::abs(corr.peakLag - lastPeakLag_) < 20);
    }
    if (std::abs(corr.peakCorrelation) > correlationThreshold && delayStable) {
        stableWindows_++;
    } else if (std::abs(corr.peakCorrelation) < correlationThreshold * 0.7f) {
        stableWindows_ = std::max(0, stableWindows_ - 1);
    }
    lastPeakLag_ = corr.peakLag;
    result.stableDelayWindows = stableWindows_;

    // 3. AEC health signals
    float aecHealth = 1.0f;
    if (aecStats.divergentFilterFraction > divergenceThreshold) aecHealth = 0.0f;
    else if (aecStats.divergentFilterFraction > 0.1f) aecHealth = 0.5f;

    // 4. Ensemble score
    float corrScore = std::clamp((std::abs(corr.peakCorrelation) - 0.2f) / 0.5f, 0.0f, 1.0f);
    float stabilityScore = std::clamp(static_cast<float>(stableWindows_) / minStableWindows, 0.0f, 1.0f);
    float rawScore = corrScore * 0.5f + stabilityScore * 0.3f + aecHealth * 0.2f;

    // Smooth
    smoothedScore_ = 0.8f * smoothedScore_ + 0.2f * rawScore;
    result.score = std::clamp(smoothedScore_, 0.0f, 1.0f);
    result.delayMs = aecStats.delayMs >= 0 ? aecStats.delayMs : (corr.peakLag * 1000 / 48000);
    result.delayStddevMs = aecStats.delayStddevMs;
    return result;
}

} // namespace dsp
