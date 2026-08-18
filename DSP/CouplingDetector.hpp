#pragma once
#include "SignalMetrics.hpp"
#include "../AECBridge/AECProcessor.hpp"
#include <cstdint>

namespace dsp {

struct CouplingResult {
    float score = 0.0f;          // 0..1
    int delayMs = -1;
    float delayStddevMs = 0.0f;
    float correlation = 0.0f;
    int stableDelayWindows = 0;
};

/// Ensemble coupling detector: correlation/coherence + AEC stats.
/// No single metric trusted alone (PLAN 13.4).
class CouplingDetector {
public:
    CouplingDetector();

    CouplingResult update(const float* render, const float* mic, size_t count,
                          const AECStats& aecStats, int maxLagSamples = 240);
    void reset();

    // Tunable thresholds (exposed for diagnostics config)
    float correlationThreshold = 0.3f;
    float divergenceThreshold = 0.3f;
    int minStableWindows = 5;

private:
    int stableWindows_ = 0;
    int lastPeakLag_ = 0;
    float smoothedScore_ = 0.0f;
};

} // namespace dsp
