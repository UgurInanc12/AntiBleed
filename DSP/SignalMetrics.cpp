#include "SignalMetrics.hpp"
#include <algorithm>
#include <cmath>
#include <limits>

namespace dsp {

float rms(const float* data, size_t count) {
    if (!data || count == 0) return 0.0f;
    double sum = 0;
    for (size_t i = 0; i < count; ++i) sum += static_cast<double>(data[i]) * data[i];
    return static_cast<float>(std::sqrt(sum / count));
}

float peak(const float* data, size_t count) {
    if (!data || count == 0) return 0.0f;
    float p = 0;
    for (size_t i = 0; i < count; ++i) p = std::max(p, std::abs(data[i]));
    return p;
}

float rmsDb(const float* data, size_t count) {
    float r = rms(data, count);
    if (r < 1e-9f) return -std::numeric_limits<float>::infinity();
    return 20.0f * std::log10(r);
}

float normalizedCorrelation(const float* a, const float* b, size_t count, int lag) {
    if (!a || !b || count == 0) return 0.0f;
    // correlate a[i] with b[i+lag]
    size_t start = lag >= 0 ? 0 : static_cast<size_t>(-lag);
    size_t end = lag >= 0 ? (count > static_cast<size_t>(lag) ? count - lag : 0) : count;
    if (end <= start) return 0.0f;
    size_t n = end - start;
    double sumA2 = 0, sumB2 = 0, sumAB = 0;
    for (size_t i = start; i < end; ++i) {
        float av = a[i];
        float bv = b[i + lag];
        sumA2 += av * av;
        sumB2 += bv * bv;
        sumAB += av * bv;
    }
    double denom = std::sqrt(sumA2 * sumB2);
    if (denom < 1e-12) return 0.0f;
    return static_cast<float>(sumAB / denom);
}

CorrelationResult maxCorrelation(const float* render, const float* mic, size_t count, int maxLag) {
    CorrelationResult r;
    for (int lag = -maxLag; lag <= maxLag; ++lag) {
        float c = normalizedCorrelation(render, mic, count, lag);
        if (std::abs(c) > std::abs(r.peakCorrelation)) {
            r.peakCorrelation = c;
            r.peakLag = lag;
        }
    }
    return r;
}

float echoAttenuationDb(const float* micComp, const float* outComp, size_t count) {
    if (!micComp || !outComp || count == 0) return 0.0f;
    float rmsMic = rms(micComp, count);
    float rmsOut = rms(outComp, count);
    if (rmsMic < 1e-9f) return 0.0f;
    if (rmsOut < 1e-9f) return 60.0f; // effectively infinite attenuation
    return 20.0f * std::log10(rmsMic / rmsOut);
}

} // namespace dsp
