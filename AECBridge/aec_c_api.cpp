#include "aec_c_api.h"
#include "AECProcessor.hpp"

#include <new>

struct abm_aec {
    AECProcessor proc;
};

extern "C" {

void abm_aec_config_default(abm_aec_config_t* cfg) {
    if (!cfg) return;
    AECConfig d;
    cfg->sample_rate_hz = d.sampleRateHz;
    cfg->capture_channels = d.numCaptureChannels;
    cfg->render_channels = d.numRenderChannels;
    cfg->enable_aec = d.enableAEC;
    cfg->enable_ns = d.enableNS;
    cfg->enable_agc = d.enableAGC;
    cfg->enable_transient = d.enableTransient;
    cfg->enable_high_pass = d.enableHighPass;
    cfg->stream_delay_hint_ms = d.streamDelayHintMs;
}

abm_aec_t* abm_aec_create(const abm_aec_config_t* cfg) {
    abm_aec_t* h = new (std::nothrow) abm_aec();
    if (!h) return nullptr;
    AECConfig c;
    if (cfg) {
        c.sampleRateHz = cfg->sample_rate_hz;
        c.numCaptureChannels = cfg->capture_channels;
        c.numRenderChannels = cfg->render_channels;
        c.enableAEC = cfg->enable_aec;
        c.enableNS = cfg->enable_ns;
        c.enableAGC = cfg->enable_agc;
        c.enableTransient = cfg->enable_transient;
        c.enableHighPass = cfg->enable_high_pass;
        c.streamDelayHintMs = cfg->stream_delay_hint_ms;
    }
    if (!h->proc.initialize(c)) {
        delete h;
        return nullptr;
    }
    return h;
}

void abm_aec_destroy(abm_aec_t* aec) { delete aec; }
void abm_aec_reset(abm_aec_t* aec) { if (aec) aec->proc.reset(); }

void abm_aec_process_render(abm_aec_t* aec, const float* render, int num_samples) {
    if (aec) aec->proc.processRenderFrame(render, num_samples);
}

void abm_aec_process_capture(abm_aec_t* aec, const float* capture, int num_samples, float* out) {
    if (aec) aec->proc.processCaptureFrame(capture, num_samples, out);
}

void abm_aec_get_stats(const abm_aec_t* aec, abm_aec_stats_t* out) {
    if (!out) return;
    AECStats s = aec ? aec->proc.getStats() : AECStats{};
    out->delay_ms = s.delayMs;
    out->delay_median_ms = s.delayMedianMs;
    out->delay_stddev_ms = s.delayStddevMs;
    out->echo_return_loss = s.echoReturnLoss;
    out->echo_return_loss_enhancement = s.echoReturnLossEnhancement;
    out->divergent_filter_fraction = s.divergentFilterFraction;
    out->residual_echo_likelihood = s.residualEchoLikelihood;
    out->residual_echo_likelihood_recent_max = s.residualEchoLikelihoodRecentMax;
    out->valid = s.valid;
}

bool abm_aec_is_real(const abm_aec_t* aec) { return aec && aec->proc.isRealAEC(); }
int abm_aec_frame_size(const abm_aec_t* aec) { return aec ? aec->proc.frameSize() : 480; }
void abm_aec_set_delay_hint_ms(abm_aec_t* aec, int delay_ms) { if (aec) aec->proc.setStreamDelayHintMs(delay_ms); }
const char* abm_aec_engine_name(void) { return AECProcessor::engineName(); }

} // extern "C"
