#include "Resampler.hpp"
#include <algorithm>
#include <cmath>

Resampler::Resampler(double fromRate, double toRate, int channels)
    : fromRate_(fromRate), toRate_(toRate), ratio_(fromRate / toRate), channels_(channels) {}

void Resampler::reset() { phase_ = 0.0; lastSample_ = 0.0f; }

size_t Resampler::process(const float* in, size_t inCount, float* out, size_t outCapacity) {
    if (!in || !out || inCount == 0) return 0;
    size_t outCount = 0;
    // Simple linear interpolation streaming
    for (size_t i = 0; i < inCount - 1 && outCount < outCapacity; ) {
        float frac = static_cast<float>(phase_ - std::floor(phase_));
        out[outCount++] = (1.0f - frac) * in[static_cast<size_t>(phase_)] +
                          frac * in[static_cast<size_t>(phase_) + 1];
        phase_ += ratio_;
        // Advance input index when phase crosses integer boundary
        while (phase_ >= 1.0 && i + 1 < inCount) {
            phase_ -= 1.0;
            ++i;
            if (phase_ < 1.0) break;
            // If ratio > 1, we may skip samples; emit next
            if (outCount < outCapacity && static_cast<size_t>(phase_) + 1 < inCount) {
                // handled in next loop iteration
            }
        }
        if (phase_ >= static_cast<double>(inCount)) break;
    }
    // Keep fractional phase for continuity
    if (phase_ >= 1.0) phase_ = std::fmod(phase_, 1.0);
    return outCount;
}
