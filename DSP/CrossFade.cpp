#include "CrossFade.hpp"
#include <cmath>
#include <algorithm>

namespace dsp {

void crossfade(const float* a, const float* b, float progress, float* out, size_t count) {
    if (!a || !b || !out) return;
    progress = std::clamp(progress, 0.0f, 1.0f);
    float inv = 1.0f - progress;
    for (size_t i = 0; i < count; ++i) out[i] = inv * a[i] + progress * b[i];
}

void crossfadeEqualPower(const float* a, const float* b, float progress, float* out, size_t count) {
    if (!a || !b || !out) return;
    progress = std::clamp(progress, 0.0f, 1.0f);
    float gA = std::cos(progress * 1.57079632679f); // cos(p * pi/2)
    float gB = std::sin(progress * 1.57079632679f);
    for (size_t i = 0; i < count; ++i) out[i] = gA * a[i] + gB * b[i];
}

void CrossfadeState::start(int numFrames) {
    totalFrames = numFrames;
    currentFrame = 0;
    active = (numFrames > 0);
}

float CrossfadeState::progress() const {
    if (!active || totalFrames == 0) return 1.0f;
    return std::clamp(static_cast<float>(currentFrame) / totalFrames, 0.0f, 1.0f);
}

void CrossfadeState::advance() {
    if (!active) return;
    ++currentFrame;
    if (currentFrame >= totalFrames) active = false;
}

void CrossfadeState::reset() {
    totalFrames = 0;
    currentFrame = 0;
    active = false;
}

} // namespace dsp
