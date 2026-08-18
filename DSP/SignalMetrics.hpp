#pragma once
#include <cstddef>
#include <cmath>

namespace dsp {

float rms(const float* data, size_t count);
float peak(const float* data, size_t count);
float rmsDb(const float* data, size_t count); // 20*log10(rms), -inf for silence

// Normalized cross-correlation at lag (positive lag = second signal delayed)
float normalizedCorrelation(const float* a, const float* b, size_t count, int lag);

// Coherence-like: peak correlation over lag range
struct CorrelationResult {
    float peakCorrelation = 0.0f;
    int peakLag = 0;
};
CorrelationResult maxCorrelation(const float* render, const float* mic, size_t count, int maxLag);

float echoAttenuationDb(const float* micRenderComponent, const float* outputRenderComponent, size_t count);

} // namespace dsp
