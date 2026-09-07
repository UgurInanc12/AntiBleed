#include "AECProcessor.hpp"

#include <algorithm>
#include <cstring>
#include <vector>

#ifndef ANTIBLEED_HAVE_WEBRTC
#define ANTIBLEED_HAVE_WEBRTC 0
#endif

#if ANTIBLEED_HAVE_WEBRTC
#include "modules/audio_processing/include/audio_processing.h"
#include "api/audio/audio_processing_statistics.h"
#include "api/scoped_refptr.h"
#endif

namespace {
constexpr int kChunkMs = 10;

inline int frameSizeFor(int sampleRateHz) {
    return sampleRateHz * kChunkMs / 1000;
}

inline bool rateSupported(int hz) {
    // AEC3 native rates. 48 kHz is the canonical one (D-007).
    return hz == 8000 || hz == 16000 || hz == 32000 || hz == 48000;
}
} // namespace

struct AECProcessor::Impl {
    AECConfig config{};
    bool initialized = false;
    int frameSize = 480;
    int streamDelayHintMs = -1;
    AECStats stats{};

#if ANTIBLEED_HAVE_WEBRTC
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig renderCfg;
    webrtc::StreamConfig captureCfg;
    // Preallocated deinterleaved channel pointers + scratch (no malloc in process*).
    std::vector<float> renderScratch;
    std::vector<float> captureScratch;
    std::vector<float*> renderPtrs;
    std::vector<float*> capturePtrs;
    std::vector<const float*> renderConstPtrs;
    std::vector<const float*> captureConstPtrs;

    bool buildApm() {
        webrtc::AudioProcessing::Config cfg;
        cfg.echo_canceller.enabled = config.enableAEC;
        cfg.echo_canceller.mobile_mode = false;
        cfg.echo_canceller.enforce_high_pass_filtering = config.enableHighPass;
        cfg.high_pass_filter.enabled = config.enableHighPass;
        cfg.noise_suppression.enabled = config.enableNS;
        cfg.gain_controller1.enabled = false;
        cfg.gain_controller2.enabled = config.enableAGC;
        cfg.transient_suppression.enabled = config.enableTransient;
        cfg.pipeline.maximum_internal_processing_rate = 48000;
        cfg.pipeline.multi_channel_render = config.numRenderChannels > 1;
        cfg.pipeline.multi_channel_capture = config.numCaptureChannels > 1;

        apm = webrtc::AudioProcessingBuilder().SetConfig(cfg).Create();
        if (!apm) return false;

        renderCfg = webrtc::StreamConfig(config.sampleRateHz, static_cast<size_t>(config.numRenderChannels));
        captureCfg = webrtc::StreamConfig(config.sampleRateHz, static_cast<size_t>(config.numCaptureChannels));

        renderScratch.assign(static_cast<size_t>(frameSize) * config.numRenderChannels, 0.0f);
        captureScratch.assign(static_cast<size_t>(frameSize) * config.numCaptureChannels, 0.0f);
        renderPtrs.resize(config.numRenderChannels);
        capturePtrs.resize(config.numCaptureChannels);
        renderConstPtrs.resize(config.numRenderChannels);
        captureConstPtrs.resize(config.numCaptureChannels);
        for (int c = 0; c < config.numRenderChannels; ++c) {
            renderPtrs[c] = renderScratch.data() + static_cast<size_t>(c) * frameSize;
            renderConstPtrs[c] = renderPtrs[c];
        }
        for (int c = 0; c < config.numCaptureChannels; ++c) {
            capturePtrs[c] = captureScratch.data() + static_cast<size_t>(c) * frameSize;
            captureConstPtrs[c] = capturePtrs[c];
        }
        if (apm->Initialize() != webrtc::AudioProcessing::kNoError) return false;
        return true;
    }

    // Interleaved -> planar scratch. For mono this is a straight copy.
    static void deinterleave(const float* in, int frames, int channels, std::vector<float*>& planes) {
        if (channels == 1) {
            std::memcpy(planes[0], in, static_cast<size_t>(frames) * sizeof(float));
            return;
        }
        for (int i = 0; i < frames; ++i)
            for (int c = 0; c < channels; ++c)
                planes[c][i] = in[i * channels + c];
    }

    static void interleave(const std::vector<float*>& planes, int frames, int channels, float* out) {
        if (channels == 1) {
            std::memcpy(out, planes[0], static_cast<size_t>(frames) * sizeof(float));
            return;
        }
        for (int i = 0; i < frames; ++i)
            for (int c = 0; c < channels; ++c)
                out[i * channels + c] = planes[c][i];
    }

    void pullStats() {
        webrtc::AudioProcessingStats s = apm->GetStatistics();
        stats.valid = s.delay_ms.has_value() || s.echo_return_loss_enhancement.has_value();
        stats.delayMs = s.delay_ms.value_or(-1);
        stats.delayMedianMs = s.delay_median_ms.value_or(-1);
        stats.delayStddevMs = s.delay_standard_deviation_ms.value_or(-1);
        stats.echoReturnLoss = static_cast<float>(s.echo_return_loss.value_or(0.0));
        stats.echoReturnLossEnhancement = static_cast<float>(s.echo_return_loss_enhancement.value_or(0.0));
        stats.divergentFilterFraction = static_cast<float>(s.divergent_filter_fraction.value_or(0.0));
        stats.residualEchoLikelihood = static_cast<float>(s.residual_echo_likelihood.value_or(0.0));
        stats.residualEchoLikelihoodRecentMax = static_cast<float>(s.residual_echo_likelihood_recent_max.value_or(0.0));
    }
#endif
};

AECProcessor::AECProcessor() : impl_(std::make_unique<Impl>()) {}
AECProcessor::~AECProcessor() = default;

bool AECProcessor::initialize(const AECConfig& config) {
    if (!rateSupported(config.sampleRateHz)) return false;
    if (config.numCaptureChannels < 1 || config.numRenderChannels < 1) return false;
    impl_->config = config;
    impl_->frameSize = frameSizeFor(config.sampleRateHz);
    impl_->streamDelayHintMs = config.streamDelayHintMs;
    impl_->stats = AECStats{};
#if ANTIBLEED_HAVE_WEBRTC
    impl_->apm = nullptr;
    if (!impl_->buildApm()) {
        impl_->initialized = false;
        return false;
    }
#endif
    impl_->initialized = true;
    return true;
}

void AECProcessor::reset() {
    impl_->stats = AECStats{};
#if ANTIBLEED_HAVE_WEBRTC
    if (impl_->apm) {
        // Full re-initialisation drops the adaptive filter (route change semantics, D-012).
        impl_->apm->Initialize();
    }
#endif
}

void AECProcessor::processRenderFrame(const float* render, int numSamples) {
    if (!impl_->initialized || !render) return;
#if ANTIBLEED_HAVE_WEBRTC
    const int ch = impl_->config.numRenderChannels;
    if (numSamples != impl_->frameSize * ch) return; // partial frames are a caller bug
    Impl::deinterleave(render, impl_->frameSize, ch, impl_->renderPtrs);
    impl_->apm->ProcessReverseStream(impl_->renderConstPtrs.data(), impl_->renderCfg,
                                     impl_->renderCfg, impl_->renderPtrs.data());
#else
    (void)numSamples;
#endif
}

void AECProcessor::processCaptureFrame(const float* capture, int numSamples, float* out) {
    if (!impl_->initialized || !capture || !out) return;
#if ANTIBLEED_HAVE_WEBRTC
    const int ch = impl_->config.numCaptureChannels;
    if (numSamples != impl_->frameSize * ch) {
        if (out != capture) std::memcpy(out, capture, static_cast<size_t>(numSamples) * sizeof(float));
        return;
    }
    Impl::deinterleave(capture, impl_->frameSize, ch, impl_->capturePtrs);
    if (impl_->streamDelayHintMs >= 0) {
        impl_->apm->set_stream_delay_ms(impl_->streamDelayHintMs);
    }
    int err = impl_->apm->ProcessStream(impl_->captureConstPtrs.data(), impl_->captureCfg,
                                        impl_->captureCfg, impl_->capturePtrs.data());
    if (err != webrtc::AudioProcessing::kNoError && err != webrtc::AudioProcessing::kBadStreamParameterWarning) {
        // Fail safe: expose raw mic, never a broken frame (D-008 / D-012).
        if (out != capture) std::memcpy(out, capture, static_cast<size_t>(numSamples) * sizeof(float));
        return;
    }
    Impl::interleave(impl_->capturePtrs, impl_->frameSize, ch, out);
    impl_->pullStats();
#else
    if (out != capture) std::memcpy(out, capture, static_cast<size_t>(numSamples) * sizeof(float));
    impl_->stats.valid = false;
#endif
}

AECStats AECProcessor::getStats() const { return impl_->stats; }
bool AECProcessor::isInitialized() const { return impl_->initialized; }
bool AECProcessor::isRealAEC() const {
#if ANTIBLEED_HAVE_WEBRTC
    return impl_->initialized && impl_->apm != nullptr;
#else
    return false;
#endif
}
int AECProcessor::frameSize() const { return impl_->frameSize; }
void AECProcessor::setStreamDelayHintMs(int delayMs) { impl_->streamDelayHintMs = delayMs; }

const char* AECProcessor::engineName() {
#if ANTIBLEED_HAVE_WEBRTC
    return "webrtc-audio-processing-2.1 (AEC3)";
#else
    return "passthrough (no WebRTC linked)";
#endif
}
