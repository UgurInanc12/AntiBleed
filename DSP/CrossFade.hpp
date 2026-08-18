#pragma once
#include <cstddef>

namespace dsp {

/// Linear crossfade: out = (1-p)*a + p*b, p in [0,1]
void crossfade(const float* a, const float* b, float progress, float* out, size_t count);

/// Equal-power crossfade (smoother loudness)
void crossfadeEqualPower(const float* a, const float* b, float progress, float* out, size_t count);

/// Ramped crossfade over N frames (480 samples each). Returns frames produced.
struct CrossfadeState {
    int totalFrames = 0;    // e.g. 10 frames = 100 ms
    int currentFrame = 0;
    bool active = false;
    void start(int numFrames);
    bool isActive() const { return active; }
    float progress() const; // 0..1
    void advance();
    void reset();
};

} // namespace dsp
