// AECProcessor unit sanity. Works with both engines:
//  - passthrough build: output must equal input bit-for-bit.
//  - real AEC3 build: with a silent render reference the capture path must
//    stay close to the input (no cancellation of non-echo content, D-008),
//    and partial frames must pass through untouched.
#include "../../AECBridge/AECProcessor.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int fail(const char* msg) {
    std::printf("FAIL: %s\n", msg);
    return 1;
}

static double rms(const float* x, int n) {
    double s = 0;
    for (int i = 0; i < n; ++i) s += double(x[i]) * x[i];
    return std::sqrt(s / n);
}

int main() {
    AECProcessor proc;
    AECConfig cfg;
    cfg.sampleRateHz = 48000;
    if (!proc.initialize(cfg)) return fail("initialize");
    if (!proc.isInitialized()) return fail("isInitialized");
    if (proc.frameSize() != 480) return fail("frameSize != 480");

    // Unsupported rate must be rejected.
    AECProcessor bad;
    AECConfig badCfg;
    badCfg.sampleRateHz = 44100;
    if (bad.initialize(badCfg)) return fail("44.1 kHz should be rejected");

    const int N = 480;
    std::vector<float> silence(N, 0.0f), in(N), out(N);
    // 1 kHz tone at -12 dBFS as "wanted" near-end content.
    for (int i = 0; i < N; ++i) in[i] = 0.25f * std::sin(2.0f * 3.14159265f * 1000.0f * i / 48000.0f);

    if (!proc.isRealAEC()) {
        proc.processRenderFrame(silence.data(), N);
        proc.processCaptureFrame(in.data(), N, out.data());
        if (std::memcmp(in.data(), out.data(), N * sizeof(float)) != 0) return fail("passthrough mismatch");
        std::printf("AEC passthrough OK (engine: %s)\n", AECProcessor::engineName());
        return 0;
    }

    // Real AEC3: render silent -> capture must survive (allow HPF/limiter tolerance).
    double inRms = 0, outRms = 0;
    for (int f = 0; f < 200; ++f) { // 2 s so the filter settles
        proc.processRenderFrame(silence.data(), N);
        proc.processCaptureFrame(in.data(), N, out.data());
        if (f >= 100) { inRms += rms(in.data(), N); outRms += rms(out.data(), N); }
    }
    double ratioDb = 20.0 * std::log10((outRms + 1e-12) / (inRms + 1e-12));
    std::printf("silent-render passthrough level: %.2f dB\n", ratioDb);
    if (ratioDb < -3.0 || ratioDb > 1.0) return fail("AEC altered near-end content with silent render");

    // Partial frame must be copied through unchanged.
    std::vector<float> part(100, 0.5f), partOut(100, 0.0f);
    proc.processCaptureFrame(part.data(), 100, partOut.data());
    if (std::memcmp(part.data(), partOut.data(), 100 * sizeof(float)) != 0) return fail("partial frame not passed through");

    // Aliasing in==out must work.
    std::vector<float> alias(in);
    proc.processRenderFrame(silence.data(), N);
    proc.processCaptureFrame(alias.data(), N, alias.data());
    if (rms(alias.data(), N) < 0.5 * rms(in.data(), N)) return fail("aliased processing lost signal");

    proc.reset();
    std::printf("AEC3 sanity OK (engine: %s)\n", AECProcessor::engineName());
    return 0;
}
