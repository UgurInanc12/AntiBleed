// aec_offline: run AECProcessor over raw Float32 mono 48 kHz files.
//
// Usage:
//   aec_offline <render.f32> <mic.f32> <out.f32> [--delay-hint <ms>] [--no-aec] [--stats-out <csv>]
//
// --stats-out writes one CSV row per frame: frame,valid,delay_ms,erl_db,erle_db,divergent,residual
//
// Frames are 480 samples (10 ms). The processing order per frame is the
// production order: render -> ProcessReverseStream, mic -> ProcessStream.
// Prints one JSON object with engine name, frame count and final AEC stats on stdout.
// Exit code 0 on success, 2 on usage error, 3 on I/O error, 4 if AEC failed to initialize.
#include "../../AECBridge/AECProcessor.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

bool readF32(const char* path, std::vector<float>& out) {
    FILE* f = std::fopen(path, "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long bytes = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (bytes < 0) { std::fclose(f); return false; }
    out.resize(static_cast<size_t>(bytes) / sizeof(float));
    size_t got = std::fread(out.data(), sizeof(float), out.size(), f);
    std::fclose(f);
    return got == out.size();
}

bool writeF32(const char* path, const std::vector<float>& data) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    size_t put = std::fwrite(data.data(), sizeof(float), data.size(), f);
    std::fclose(f);
    return put == data.size();
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: aec_offline <render.f32> <mic.f32> <out.f32> [--delay-hint ms] [--no-aec]\n");
        return 2;
    }
    int delayHint = -1;
    bool enableAEC = true;
    const char* statsOut = nullptr;
    for (int i = 4; i < argc; ++i) {
        if (std::strcmp(argv[i], "--delay-hint") == 0 && i + 1 < argc) delayHint = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--no-aec") == 0) enableAEC = false;
        else if (std::strcmp(argv[i], "--stats-out") == 0 && i + 1 < argc) statsOut = argv[++i];
    }

    std::vector<float> render, mic;
    if (!readF32(argv[1], render) || !readF32(argv[2], mic)) {
        std::fprintf(stderr, "failed to read inputs\n");
        return 3;
    }

    AECProcessor proc;
    AECConfig cfg;
    cfg.sampleRateHz = 48000;
    cfg.enableAEC = enableAEC;
    cfg.streamDelayHintMs = delayHint;
    if (!proc.initialize(cfg)) {
        std::fprintf(stderr, "AEC initialize failed\n");
        return 4;
    }

    const int N = proc.frameSize();
    size_t frames = std::min(render.size(), mic.size()) / static_cast<size_t>(N);
    std::vector<float> out(frames * N, 0.0f);
    FILE* statsFile = statsOut ? std::fopen(statsOut, "w") : nullptr;
    if (statsFile) std::fprintf(statsFile, "frame,valid,delay_ms,erl_db,erle_db,divergent,residual\n");
    for (size_t i = 0; i < frames; ++i) {
        proc.processRenderFrame(render.data() + i * N, N);
        proc.processCaptureFrame(mic.data() + i * N, N, out.data() + i * N);
        if (statsFile) {
            AECStats f = proc.getStats();
            std::fprintf(statsFile, "%zu,%d,%d,%.3f,%.3f,%.4f,%.4f\n", i, f.valid ? 1 : 0, f.delayMs,
                         f.echoReturnLoss, f.echoReturnLossEnhancement, f.divergentFilterFraction, f.residualEchoLikelihood);
        }
    }
    if (statsFile) std::fclose(statsFile);
    if (!writeF32(argv[3], out)) {
        std::fprintf(stderr, "failed to write output\n");
        return 3;
    }

    AECStats s = proc.getStats();
    std::printf("{\"engine\":\"%s\",\"real_aec\":%s,\"frames\":%zu,\"stats_valid\":%s,"
                "\"delay_ms\":%d,\"delay_median_ms\":%d,\"delay_stddev_ms\":%d,"
                "\"erl_db\":%.3f,\"erle_db\":%.3f,\"divergent_filter_fraction\":%.4f,"
                "\"residual_echo_likelihood\":%.4f,\"residual_echo_likelihood_recent_max\":%.4f}\n",
                AECProcessor::engineName(), proc.isRealAEC() ? "true" : "false", frames,
                s.valid ? "true" : "false", s.delayMs, s.delayMedianMs, s.delayStddevMs,
                s.echoReturnLoss, s.echoReturnLossEnhancement, s.divergentFilterFraction,
                s.residualEchoLikelihood, s.residualEchoLikelihoodRecentMax);
    return 0;
}
