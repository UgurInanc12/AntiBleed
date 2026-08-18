# Phase 4: Offline WebRTC AEC3

> PLAN.md chapters: 7, 8, 12, 20, 21, 28, 31, 32, 33, 34, 46.
> Prerequisite: Phase 3 DONE - bounded sync proven for 30+ minutes, frame assembler stable.
> Status: NOT STARTED

## Objective

Integrate the real WebRTC Audio Processing Module / AEC3 engine and prove it cancels synthetic echo offline - before any live hardware is fed into it. This is the algorithmic core; synthetic tests are deterministic and CI-runnable, so failures are reproducible without a Mac speaker.

Follows PLAN chapters 12 ("WebRTC AEC3 integration"), 28 ("Offline DSP test harness"), and 33 ("Build strategy for WebRTC").

## Step 1: Pin and fetch WebRTC

### Version pin

Record in the repo root (e.g., `WEBRTC_REVISION` file or `Scripts/build-webrtc.sh` header):

```text
WEBRTC_REVISION=<40-char commit SHA>   # e.g., from refs/heads/main at time of Phase 4 start
WEBRTC_BUILD_GN_ARGS=is_debug=false rtc_include_tests=false use_custom_libcxx=false
```

Never float on `main` in production. Every phase records the exact SHA in diagnostics.

### Fetch - do not vendor the checkout

The WebRTC checkout is multi-GB. Do not commit it.

On the Mac / in CI, `Scripts/build-webrtc.sh` does:

```bash
#!/bin/bash
set -euo pipefail
WEBRTC_REVISION="$(cat WEBRTC_REVISION)"
DEPOT_TOOLS_DIR="${HOME}/dev/depot_tools"

# 1. depot_tools
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
fi
export PATH="$DEPOT_TOOLS_DIR:$PATH"

# 2. fetch WebRTC outside the repo
WORKDIR="${HOME}/dev/webrtc-checkout"
mkdir -p "$WORKDIR" && cd "$WORKDIR"
if [ ! -d src ]; then fetch --nohooks webrtc; fi
cd src
git fetch origin
git checkout "$WEBRTC_REVISION"
gclient sync --nohooks

# 3. GN + Ninja: build only APM targets where practical
gn gen out/Release --args='is_debug=false rtc_include_tests=false use_custom_libcxx=false treat_warnings_as_errors=false'
ninja -C out/Release audio_processing

# 4. Archive static libs + headers + NOTICE/LICENSES into build/webrtc/
# 5. Copy to repo-local build/webrtc/ for the Xcode project to link (gitignored; CI caches the archive)
```

Cache the built archive in GitHub Actions (`actions/cache` keyed by `WEBRTC_REVISION`) to avoid rebuilding every run. Record licenses/NOTICE files with the release per PLAN 33.

References to read before coding:

- `https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/development/`
- `https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/g3doc/audio_processing_module.md`
- `https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h`
- `https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/echo_canceller3_config.h`

Do not guess signatures from old blog posts - read the pinned revision's headers.

## Step 2: C++ wrapper - AECBridge / AECProcessor

### AECProcessor.hpp (Phase 4 real implementation)

```cpp
#pragma once
#include <cstdint>
#include <memory>

namespace webrtc { class AudioProcessing; }

struct AECConfig {
    int sampleRateHz = 48000;
    int numCaptureChannels = 1;
    int numRenderChannels = 1;
    bool enableAEC = true;
    bool enableNS = false;       // OFF by default
    bool enableAGC = false;      // OFF
    bool enableTransient = false;
    // AEC3 tuning overrides (optional, from EchoCanceller3Config)
};

struct AECStats {
    int delayMs = -1;
    int delayMedianMs = -1;
    int delayStddevMs = -1;
    float echoReturnLoss = 0.f;
    float echoReturnLossEnhancement = 0.f;
    float divergentFilterFraction = 0.f;
    float residualEchoLikelihood = 0.f;
    // Add more from AudioProcessingStatistics as needed
};

class AECProcessor {
public:
    AECProcessor();
    ~AECProcessor();

    bool initialize(const AECConfig& config);
    void reset();

    // Render (far-end) - must be called BEFORE the corresponding capture frame
    void processRenderFrame(const float* render, int numSamples); // 480 @ 48k mono

    // Capture (near-end) - produces cleaned output
    void processCaptureFrame(const float* capture, int numSamples, float* out);

    AECStats getStats() const;
    bool isInitialized() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
```

### AECBridge.h/.mm (Objective-C++ glue, Swift-visible)

```objc
// AECBridge.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface AECBridge : NSObject
- (BOOL)initializeWithSampleRate:(int)hz captureChannels:(int)cc renderChannels:(int)rc;
- (void)processRenderFrame:(const float *)render numSamples:(int)n;
- (void)processCaptureFrame:(const float *)capture numSamples:(int)n out:(float *)out;
- (NSDictionary *)getStats; // delayMs, erl, erle, etc.
- (void)reset;
@end
NS_ASSUME_NONNULL_END
```

```objc
// AECBridge.mm - thin forwarding to AECProcessor
#import "AECBridge.h"
#import "AECProcessor.hpp"
@implementation AECBridge { AECProcessor _proc; }
// forward each method to _proc
@end
```

Build integration:

- `AECBridge/CMakeLists.txt` links against the archived `libaudio_processing.a` (and its transitive deps - `abseil`, `boringssl` etc. as produced by the WebRTC build). In Xcode, add the archive as a linked library and the WebRTC `api/` headers to the search path.
- Pin `CMAKE_CXX_STANDARD` (17 or 20) and record it in `DECISIONS.md` under D-014.

### Processing order (PLAN 12.1)

For each matched 10 ms window:

```text
1. feed render frame -> ProcessReverseStream
2. feed corresponding raw mic frame -> ProcessStream
3. read AEC-cleaned mic frame from ProcessStream output
```

Maintain order even if Core Audio callback sizes differ from 480 - the `FrameAssembler` from Phase 3 guarantees 480 boundaries; the wrapper must not be called with partial frames.

### Configuration (PLAN 12.2)

Start conservatively:

```text
echo_canceller.enabled = true
noise_suppression.enabled = false
gain_controller.enabled = false
transient_suppression.enabled = false
```

Do not add NS/AGC to make demo recordings sound artificially impressive. The test is bleed removal, not voice enhancement.

## Step 3: Keep AEC warm even when output is bypassed (PLAN 12.3)

Separate `AEC processing state` from `which signal is exposed`. During BYPASS/LEARNING:

- AEC continues to receive render+mic pairs and adapt internally.
- The virtual mic still outputs raw mic.

This lets AEC converge without exposing unstable artifacts to Discord. `AntiBleedPipeline` will later gate the output; `AECProcessor` always processes.

## Step 4: Offline test harness (Python + C++)

PLAN chapter 28 specifies deterministic offline tests. Implement them as pytest (Python generates fixtures) + C++ (AECProcessor consumes them) or fully in Python with a C++ subprocess - either way, fixtures are committed and CI-runnable without a Mac.

### Synthetic signal generation

Generate (Python, `Tests/OfflineFixtures/generate.py`):

```text
render(t)        - far-end signal (speech-shaped noise, sine sweeps, real speech clips)
wantedVoice(t)   - near-end speech (sine + harmonics, or LibriSpeech excerpts if licensed)
noise(t)         - ambient (white/pink, low level)
syntheticRoomIR  - FIR impulse response (single tap, multi-tap, measured if available)

mic(t) = wantedVoice(t) + noise(t) + convolution(render(t), syntheticRoomIR)
```

Commit at least one deterministic IR and one set of render/wanted waveforms as `Tests/OfflineFixtures/*.wav` + `*.json` manifests so CI can run without regenerating.

### Required cases (PLAN 28.1)

| Case | Description | Input | Expected output |
|------|-------------|-------|-----------------|
| A | Fixed echo, known FIR | `mic = voice + render*IR` | Strong render suppression, voice preserved |
| B | Delay sweep 0-250 ms | Vary IR delay | Stable across delay range |
| C | Amplitude sweep | Vary `h(t)` gain | Graceful degradation at extremes |
| D | Room reflections | Multi-tap IR | AEC tracks multi-path |
| E | Double-talk | Render + wanted simultaneously | Voice intelligible, far-end suppressed |
| F | Render only, no near-end | `mic = render*IR` | Strong attenuation |
| G | Wanted only, render silent | `mic = voice` | Output approx raw mic, no coloration |
| H | Headphones/no coupling | `mic = voice + noise` (render active but not in mic) | Output approx raw mic, NO inverse render |
| I | Clock drift | Resample one stream by +/- 50 ppm | Bounded quality loss |
| J | Route change | Abrupt IR change mid-stream | Temporary bypass, relearn, reactivate |

### Metrics per case

Compute in `Tests/DSPTests/metrics.py` or C++:

```text
RMS, peak, correlation(render, mic), correlation(render, output)
Echo attenuation (ERLE-like): 10*log10(power(mic_render_component) / power(output_render_component))
Wanted-speech distortion: correlation(wanted, output) and spectral distance
Output vs raw in bypass cases: difference must be below threshold (no injection)
Latency alignment: cross-correlation peak delay
Clipping count
```

Critical regression (PLAN 31):

```text
render active, no render component in microphone  =>  final output must NOT acquire a render-correlated component.
This protects "no inverse desktop audio."
```

### Harness wiring

```text
Tests/
├── OfflineFixtures/
│   ├── generate.py              # Python: renders mic = voice + conv(render, IR)
│   ├── fixtures.json            # manifests (IR, sample rates, seeds)
│   └── *.wav                    # committed deterministic fixtures
├── DSPTests/
│   ├── test_ring_buffer.cpp
│   ├── test_resampler.cpp
│   └── test_signal_metrics.cpp
├── AECTests/
│   ├── test_aec_offline.cpp     # feeds fixtures through AECProcessor, asserts metrics
│   └── cases/
│       ├── case_a_fixed_echo.cpp
│       └── ...
└── requirements.txt             # numpy, scipy, soundfile (for generate.py)
```

On Windows: `uv run python Tests/OfflineFixtures/generate.py && uv run pytest Tests/` exercises the Python side without a Mac. On macOS/CI: the C++ tests link against the real AEC3 archive and run the same fixtures.

## Step 5: Build and CI

- `Scripts/build-webrtc.sh` must succeed on the Mac and on the macOS CI runner (with caching). Log `WEBRTC_REVISION` at the start of every build.
- `AECBridge` must compile as a static library and expose `AECBridge.h` cleanly to Swift.
- `ctest --test-dir build` runs the C++ harness; `pytest Tests/` runs the Python generator checks; both are gates in `macos-build.yml` and `unit-tests.yml`.

## Acceptance criteria

- [ ] `WEBRTC_REVISION` pinned in the repo; `Scripts/build-webrtc.sh` fetches, builds, and archives APM on the Mac and in CI (cache hit on second run).
- [ ] `AECBridge` / `AECProcessor` compiles and links against the archived APM; Swift can `import AECBridge` and call `processRenderFrame`/`processCaptureFrame` without crash.
- [ ] Offline cases A-J all pass with thresholds recorded in `Tests/AECTests/cases/*.json` or `Docs/DSP.md` (attenuation dB, distortion, bypass fidelity).
- [ ] Case G (wanted only) and Case H (no coupling) prove no coloration: output RMS within 0.5 dB of raw, correlation(render, output) < 0.05 - the no-inverse guard.
- [ ] Case E (double-talk) preserves near-end: correlation(wanted, output) > 0.85 (tunable; record the measured value, then pin it).
- [ ] Case I (drift) and Case J (route change) behave as specified; route change triggers bypass/relearn in the pipeline stub.
- [ ] Metrics scripts compute RMS/peak/correlation/ERLE/distortion/latency/clipping and are run in CI; results are deterministic for fixed fixtures.
- [ ] No WebRTC checkout committed to the repo; licenses/NOTICE archived with releases.
- [ ] `Docs/DSP.md` updated with AEC3 integration notes, config used, and measured offline results.

## Pitfalls

- Guessing `AudioProcessing` API signatures from blog posts - always open the pinned revision's `audio_processing.h` and `echo_canceller3_config.h`.
- Building WebRTC against floating `main` - pins exist for reproducibility; CI must fail if `WEBRTC_REVISION` is missing.
- Enabling NS/AGC "to make it sound better" - forbidden by default; measure AEC alone first.
- Committing the multi-GB `webrtc-checkout/` - it is always outside the repo.
- Running only synthetic sine tests - include speech-like signals; AEC3 is tuned for speech spectra.

## Next phase gate

Phase 5 may start only when offline cases A-J pass with recorded metrics and the no-inverse regression (Case H) is green. Synthetic quality is the gate, not "AEC linked successfully."
