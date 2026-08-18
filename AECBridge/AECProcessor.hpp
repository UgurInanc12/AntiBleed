#pragma once
#include <cstdint>
#include <memory>
#include <vector>

// Phase 0: standalone passthrough stub.
// Phase 4: delegates to webrtc::AudioProcessing / AEC3.

struct AECConfig {
    int sampleRateHz = 48000;
    int numCaptureChannels = 1;
    int numRenderChannels = 1;
    bool enableAEC = true;
    bool enableNS = false;
    bool enableAGC = false;
    bool enableTransient = false;
};

struct AECStats {
    int delayMs = -1;
    int delayMedianMs = -1;
    int delayStddevMs = -1;
    float echoReturnLoss = 0.0f;
    float echoReturnLossEnhancement = 0.0f;
    float divergentFilterFraction = 0.0f;
    float residualEchoLikelihood = 0.0f;
};

class AECProcessor {
public:
    AECProcessor();
    ~AECProcessor();

    AECProcessor(const AECProcessor&) = delete;
    AECProcessor& operator=(const AECProcessor&) = delete;

    bool initialize(const AECConfig& config);
    void reset();

    // Render (far-end) must be called BEFORE the corresponding capture frame.
    void processRenderFrame(const float* render, int numSamples);

    // Capture (near-end) produces cleaned output. numSamples must be 480 @ 48k.
    void processCaptureFrame(const float* capture, int numSamples, float* out);

    AECStats getStats() const;
    bool isInitialized() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
