// C ABI for AECProcessor so Swift (via the AECBridgeC system-library module)
// and any other language can drive the echo canceller without Objective-C++.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct abm_aec abm_aec_t;

typedef struct abm_aec_config {
    int sample_rate_hz;      // 48000
    int capture_channels;    // 1
    int render_channels;     // 1
    bool enable_aec;         // true
    bool enable_ns;          // false (D-006)
    bool enable_agc;         // false
    bool enable_transient;   // false
    bool enable_high_pass;   // true
    int stream_delay_hint_ms; // -1 = auto
} abm_aec_config_t;

typedef struct abm_aec_stats {
    int delay_ms;
    int delay_median_ms;
    int delay_stddev_ms;
    float echo_return_loss;
    float echo_return_loss_enhancement;
    float divergent_filter_fraction;
    float residual_echo_likelihood;
    float residual_echo_likelihood_recent_max;
    bool valid;
} abm_aec_stats_t;

// Fills defaults matching AECConfig in AECProcessor.hpp.
void abm_aec_config_default(abm_aec_config_t* cfg);

// Returns NULL if the configuration is unsupported.
abm_aec_t* abm_aec_create(const abm_aec_config_t* cfg);
void abm_aec_destroy(abm_aec_t* aec);

void abm_aec_reset(abm_aec_t* aec);
void abm_aec_process_render(abm_aec_t* aec, const float* render, int num_samples);
// out may alias capture.
void abm_aec_process_capture(abm_aec_t* aec, const float* capture, int num_samples, float* out);
void abm_aec_get_stats(const abm_aec_t* aec, abm_aec_stats_t* out);
bool abm_aec_is_real(const abm_aec_t* aec);
int abm_aec_frame_size(const abm_aec_t* aec);
void abm_aec_set_delay_hint_ms(abm_aec_t* aec, int delay_ms);
const char* abm_aec_engine_name(void);

#ifdef __cplusplus
}
#endif
