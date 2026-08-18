#include "AECProcessor.hpp"
#include <cstring>
#include <algorithm>

struct AECProcessor::Impl {
    AECConfig config{};
    bool initialized = false;
    // Phase 0: simple passthrough state
    // Phase 4: holds webrtc::AudioProcessing* and AEC3 config
    AECStats stats{};
};

AECProcessor::AECProcessor() : impl_(std::make_unique<Impl>()) {}
AECProcessor::~AECProcessor() = default;

bool AECProcessor::initialize(const AECConfig& config) {
    impl_->config = config;
    impl_->initialized = true;
    impl_->stats = AECStats{};
    return true;
}

void AECProcessor::reset() {
    impl_->stats = AECStats{};
}

void AECProcessor::processRenderFrame(const float* /*render*/, int /*numSamples*/) {
    if (!impl_->initialized) return;
    // Phase 0: store for diagnostics only. Phase 4: forward to APM ProcessReverseStream.
}

void AECProcessor::processCaptureFrame(const float* capture, int numSamples, float* out) {
    if (!impl_->initialized || !capture || !out) return;
    // Phase 0: passthrough (no cancellation). Phase 4: APM ProcessStream.
    std::memcpy(out, capture, static_cast<size_t>(numSamples) * sizeof(float));
    // Update trivial stats for diagnostics
    impl_->stats.delayMs = -1;
}

AECStats AECProcessor::getStats() const {
    return impl_->stats;
}

bool AECProcessor::isInitialized() const {
    return impl_->initialized;
}
