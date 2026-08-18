#pragma once
#include <cstddef>
#include <vector>

// Minimal streaming resampler placeholder.
// Phase 0-3: supports 44.1k<->48k via linear interpolation with persistent state.
// Phase 4+: may wrap a higher-quality resampler (e.g. speex/samplerate).
class Resampler {
public:
    Resampler(double fromRate, double toRate, int channels = 1);
    void reset();
    // Process interleaved or mono. Returns number of output samples written.
    size_t process(const float* in, size_t inCount, float* out, size_t outCapacity);
    double latencySamples() const { return 0.0; } // TODO: account for filter delay if upgraded
private:
    double fromRate_, toRate_, ratio_;
    int channels_;
    double phase_ = 0.0;
    float lastSample_ = 0.0f;
};
