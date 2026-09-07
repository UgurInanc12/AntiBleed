#pragma once
#include <cstdint>
#include <memory>

// AECProcessor: thin, real-time friendly wrapper around WebRTC Audio Processing
// Module (APM) with Echo Canceller 3 (AEC3).
//
// Build modes:
//   ANTIBLEED_HAVE_WEBRTC=1  -> real APM/AEC3 (webrtc-audio-processing 2.x)
//   ANTIBLEED_HAVE_WEBRTC=0  -> passthrough fallback. Output == input. Never
//                              subtracts render. Used only when the library
//                              is unavailable; isRealAEC() reports false so the
//                              pipeline can stay in BYPASS.
//
// Canonical format (D-007): 48 kHz, Float32, 10 ms frames = 480 samples/channel.
// Call order per frame (PLAN 12.1): processRenderFrame() then processCaptureFrame().

struct AECConfig {
    int sampleRateHz = 48000;
    int numCaptureChannels = 1;
    int numRenderChannels = 1;
    bool enableAEC = true;
    bool enableNS = false;          // OFF by default (D-006)
    bool enableAGC = false;         // OFF
    bool enableTransient = false;   // OFF
    bool enableHighPass = true;     // AEC3 enforces HPF anyway; keep explicit
    // Estimated render->capture system delay hint in ms (-1 = let AEC3 estimate).
    int streamDelayHintMs = -1;
};

struct AECStats {
    int delayMs = -1;                     // AEC3 estimated delay (render vs capture)
    int delayMedianMs = -1;
    int delayStddevMs = -1;
    float echoReturnLoss = 0.0f;          // ERL  (dB)
    float echoReturnLossEnhancement = 0.0f; // ERLE (dB): how much echo AEC removed
    float divergentFilterFraction = 0.0f; // 0 = healthy, >0.3 = filter diverging
    float residualEchoLikelihood = 0.0f;  // 0..1
    float residualEchoLikelihoodRecentMax = 0.0f;
    bool valid = false;                   // false when APM has not produced stats yet
};

class AECProcessor {
public:
    AECProcessor();
    ~AECProcessor();

    AECProcessor(const AECProcessor&) = delete;
    AECProcessor& operator=(const AECProcessor&) = delete;

    // Creates the APM. Returns false if the requested config is not supported.
    bool initialize(const AECConfig& config);

    // Drops all adaptive state (route change, device switch). Keeps config.
    void reset();

    // Render (far-end) frame. MUST be called before the matching capture frame.
    // numSamples must equal frameSize() (480 at 48 kHz) times render channels
    // interleaved. Mono render is expected by the pipeline (stereo downmixed).
    void processRenderFrame(const float* render, int numSamples);

    // Capture (near-end) frame. Produces the echo-cancelled frame into out.
    // out may alias capture. On any internal error the input is copied through
    // unchanged (never silence, never inverted render).
    void processCaptureFrame(const float* capture, int numSamples, float* out);

    AECStats getStats() const;
    bool isInitialized() const;

    // True when a real AEC3 engine is compiled in and active.
    bool isRealAEC() const;

    // Samples per channel per 10 ms frame for the configured rate.
    int frameSize() const;

    // Optional: feed an explicit delay estimate (ms) for AEC3's delay search.
    void setStreamDelayHintMs(int delayMs);

    // Compile-time engine identifier for diagnostics ("webrtc-apm-2.1" / "passthrough").
    static const char* engineName();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
