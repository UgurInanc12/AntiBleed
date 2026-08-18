// Phase 0: AEC passthrough sanity (no WebRTC yet).
// Phase 4: replaced by real APM tests against fixtures.
#include "../../AECBridge/AECProcessor.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

int main() {
    AECProcessor proc;
    AECConfig cfg;
    cfg.sampleRateHz = 48000;
    assert(proc.initialize(cfg));
    assert(proc.isInitialized());

    float in[480], out[480];
    for (int i = 0; i < 480; ++i) in[i] = float(i) / 480.0f;

    proc.processRenderFrame(in, 480);
    proc.processCaptureFrame(in, 480, out);

    // Phase 0: passthrough, so out == in
    for (int i = 0; i < 480; ++i) {
        if (out[i] != in[i]) {
            printf("FAIL: passthrough mismatch at %d: %f != %f\n", i, out[i], in[i]);
            return 1;
        }
    }

    auto stats = proc.getStats();
    (void)stats;

    proc.reset();
    printf("AEC passthrough OK\n");
    return 0;
}
