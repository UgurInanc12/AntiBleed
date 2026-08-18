# Phase 0: Repository and Build Skeleton

> PLAN.md chapters: 5, 6, 7, 32, 35, 48.
> Prerequisite: ANTI_BLEED_MIC_PLAN.md frozen at D:\Hermes\ANTI_BLEED_MIC\ANTI_BLEED_MIC_PLAN.md.
> Status: NOT STARTED

## Objective

Stand up the repository, the Xcode project, the C++ bridge skeleton, and CI so that a clean clone builds on a Mac. No DSP, no audio capture yet. This phase proves the build chain before any signal processing is introduced. Follows PLAN chapter 48: "The first engineering PR should contain only the skeleton."

## Why this order

The highest technical risk is synchronized AEC, not making a device appear. If the build chain is broken, every later phase is blocked. Phase 0 isolates that risk with a trivially verifiable artifact: `clean clone -> build succeeds on Mac`.

## Step 1: Repository bootstrap

```text
1. Create GitHub repository (PRIVATE initially):
     github.com/UgurInanc12/AntiBleed   [name TBD - confirm with Ugur before creation]
   Alternative local-only start: keep D:\Hermes\ANTI_BLEED_MIC as the git root
   and push when the Mac + CI are ready. Either way, this directory IS the repo.

2. Initialize git in D:\Hermes\ANTI_BLEED_MIC if not already a repo:
     git init
     git add README.md .gitignore phases/ Docs/ ANTI_BLEED_MIC_PLAN.md
     git commit -m "chore: initial repo skeleton and development plan"

3. Remote (when created):
     git remote add origin git@github.com:UgurInanc12/AntiBleed.git
     git push -u origin main

4. Branch policy from day one:
     main is protected; feature branches -> PR -> CI green -> merge.
     Never --force, only --force-with-lease after verifying HEAD.
```

## Step 2: Repository layout (PLAN chapter 7)

Create exactly this tree - empty files/stubs are acceptable in Phase 0, but the paths must exist so later phases have a stable import map:

```text
AntiBleed/
├── README.md
├── ANTI_BLEED_MIC_PLAN.md
├── LICENSE                          # TBD - decide before public release; see D-010 re BlackHole GPL
├── .gitignore
├── .github/
│   └── workflows/
│       ├── macos-build.yml
│       └── unit-tests.yml
├── phases/
│   ├── README.md
│   ├── DECISIONS.md
│   └── PHASE-0..11-*.md
├── Docs/
│   ├── Architecture.md
│   ├── DSP.md
│   ├── Driver.md
│   ├── Permissions.md
│   ├── Testing.md
│   └── Distribution.md
├── AntiBleedApp/
│   ├── AntiBleedApp.xcodeproj/      # created on the Mac (see Step 3)
│   ├── App/
│   │   ├── AntiBleedApp.swift
│   │   ├── AppState.swift
│   │   └── Permissions.swift
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   ├── DeviceSelectorView.swift
│   │   ├── DiagnosticsView.swift
│   │   └── SettingsView.swift
│   └── Audio/
│       ├── DeviceManager.swift
│       ├── MicrophoneCapture.swift
│       ├── SystemAudioTap.swift
│       ├── AggregateDeviceManager.swift
│       ├── AudioSynchronizer.swift
│       ├── FormatConverter.swift
│       ├── AntiBleedPipeline.swift
│       └── VirtualMicWriter.swift
├── AECBridge/
│   ├── AECBridge.h
│   ├── AECBridge.mm
│   ├── AECProcessor.hpp
│   ├── AECProcessor.cpp
│   └── CMakeLists.txt
├── AntiBleedDriver/
│   ├── Driver/
│   ├── SharedRingBuffer/
│   ├── Info.plist
│   └── README.md
├── DSP/
│   ├── RingBuffer.hpp
│   ├── Resampler.hpp / .cpp
│   ├── SignalMetrics.hpp / .cpp
│   ├── CouplingDetector.hpp / .cpp
│   └── CrossFade.hpp / .cpp
├── Tests/
│   ├── DSPTests/
│   ├── AECTests/
│   ├── SynchronizationTests/
│   ├── DriverTests/
│   ├── OfflineFixtures/
│   ├── HardwareTestProtocol.md
│   └── requirements.txt             # Python offline harness deps (Phase 4+)
└── Scripts/
    ├── bootstrap-macos.sh
    ├── build-webrtc.sh
    ├── build-app.sh
    ├── install-driver.sh
    ├── uninstall-driver.sh
    └── package.sh
```

On Windows this is created with `mkdir -p` + placeholder `README.md` stubs. The Xcode project itself is created on the Mac in Step 3.

## Step 3: Xcode project (on the Mac only)

Do not attempt this on Windows - Xcode does not exist there.

```text
1. On the Mac, open the cloned repo.
2. Xcode -> New Project -> macOS -> App:
     Product Name: AntiBleedApp
     Interface: SwiftUI
     Language: Swift
     Minimum deployment: macOS 14.2
3. Move the generated sources into AntiBleedApp/App/ to match the layout above.
4. Add a second target for the Audio Server Plug-in:
     File -> New -> Target -> Bundle -> Audio Server Plug-in (or Bundle template,
     then configure as HAL plug-in per Apple sample:
     developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
     Product: AntiBleed.driver
     Bundle ID: com.antibleed.driver
     Install path: /Library/Audio/Plug-Ins/HAL
5. Add AECBridge as a static library target (Objective-C++):
     Sources: AECBridge.h/.mm, AECProcessor.hpp/.cpp
     Language dialect: C++17 or C++20 (pin it, record in DECISIONS.md)
6. Set build settings:
     SWIFT_VERSION = 5.0
     MACOSX_DEPLOYMENT_TARGET = 14.2
     CODE_SIGN_STYLE = Manual (until signing certs are in CI)
     HARDENED_RUNTIME = YES (prepare for notarization, Phase 11)
7. Verify the empty app launches:
     Product -> Build (Cmd+B) -> green.
     Product -> Run -> menu-bar stub appears, no crash.
```

Record the exact Xcode version used in `phases/DECISIONS.md` as part of D-014 (pin it).

## Step 4: C++ bridge skeleton (no WebRTC yet)

`AECBridge/` in Phase 0 is a compiling stub so the Swift <-> C++ boundary is proven before WebRTC is fetched.

```cpp
// AECBridge/AECProcessor.hpp (Phase 0 stub)
#pragma once
#include <cstdint>
#include <vector>

class AECProcessor {
public:
    bool initialize(int sampleRate, int numCaptureChannels, int numRenderChannels);
    // Phase 0: passthrough. Phase 4: delegates to WebRTC APM.
    void processCaptureFrame(const float* capture, int numSamples, float* out);
    void processRenderFrame(const float* render, int numSamples);
    void reset();
};
```

```objc
// AECBridge/AECBridge.h (Phase 0 - Swift-visible)
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface AECBridge : NSObject
- (BOOL)initializeWithSampleRate:(int)sampleRate;
- (void)processCaptureFrame:(const float *)capture numSamples:(int)n out:(float *)out;
- (void)processRenderFrame:(const float *)render numSamples:(int)n;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
```

```cmake
# AECBridge/CMakeLists.txt (Phase 0)
cmake_minimum_required(VERSION 3.20)
project(AECBridge LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
add_library(AECBridge STATIC AECProcessor.cpp AECBridge.mm)
target_include_directories(AECBridge PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
```

Swift side imports via bridging header or module map - verify `import AECBridge` compiles in `AntiBleedApp.swift`.

## Step 5: DSP stubs (no algorithm yet)

`DSP/RingBuffer.hpp` is the only file that needs a real implementation in Phase 0 - it is the foundation for every later phase. The rest can be headers with TODO.

```cpp
// DSP/RingBuffer.hpp - Phase 0 must be a working lock-free SPSC ring
// Requirements (PLAN chapter 11.3):
//   - bounded, preallocated, no malloc in push/pop
//   - no blocking mutex on the audio thread
//   - defined overflow (drop oldest) and underflow (output silence) policies
//   - telemetry counters: overruns, underruns, current depth
// Verify with unit tests before any audio code uses it.
```

Suggested API (adapt as needed):

```cpp
template<typename T, size_t Capacity>
class RingBuffer {
public:
    bool push(const T* data, size_t count);  // returns false on overflow (counted)
    size_t pop(T* out, size_t count);        // returns actual popped; silence on underflow
    size_t available() const;
    size_t freeSpace() const;
    uint64_t overruns() const;
    uint64_t underruns() const;
    void reset();
};
```

## Step 6: Scripts (stubs, executable)

Create executable stubs so CI and the Mac bootstrap have stable paths:

```bash
# Scripts/bootstrap-macos.sh
#!/bin/bash
set -euo pipefail
echo "[bootstrap] Phase 0: verify Xcode + CLT"
xcodebuild -version
xcrun --version
# Phase 4 will append: depot_tools install, GN/Ninja verify

# Scripts/build-app.sh
#!/bin/bash
set -euo pipefail
xcodebuild -project AntiBleedApp/AntiBleedApp.xcodeproj \
  -scheme AntiBleedApp -configuration Debug build

# Scripts/build-webrtc.sh - stub in Phase 0, real in Phase 4
#!/bin/bash
echo "WebRTC build not yet implemented (Phase 4). WEBRTC_REVISION=[TBD]"

# Scripts/install-driver.sh / uninstall-driver.sh / package.sh - stubs
```

`chmod +x Scripts/*.sh` on the Mac. On Windows, `git update-index --chmod=+x` so the bit is stored.

## Step 7: CI - GitHub Actions

Two workflows. Both must be green before Phase 0 is considered done.

### .github/workflows/macos-build.yml (runs on macos-14+)

```yaml
name: macOS Build
on: [push, pull_request]
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_*.app  # pin exact version, see D-014
      - name: Verify toolchain
        run: |
          xcodebuild -version
          xcrun --version
          clang --version
          cmake --version || echo "cmake not required until Phase 4"
      - name: Build Swift app
        run: ./Scripts/build-app.sh
      - name: Build C++ bridge
        run: |
          cmake -S AECBridge -B build/aec -DCMAKE_BUILD_TYPE=Release
          cmake --build build/aec
      - name: Run DSP unit tests (when present)
        run: ctest --test-dir build/aec --output-on-failure || true  # strict from Phase 1
```

### .github/workflows/unit-tests.yml (runs on any OS, for platform-independent DSP)

```yaml
name: Unit Tests (cross-platform)
on: [push, pull_request]
jobs:
  dsp-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and test DSP
        run: |
          cmake -S . -B build -DDSP_TESTS=ON  # when DSP/CMakeLists.txt exists
          cmake --build build
          ctest --test-dir build --output-on-failure
      - name: Python offline harness
        run: |
          pip install -r Tests/requirements.txt
          pytest Tests/ -v
```

In Phase 0 the second workflow may be a no-op that simply checks the repo layout - that is acceptable as long as it is green. From Phase 1 it becomes strict.

## Step 8: Docs stubs

Create `Docs/*.md` with a one-paragraph scope note and a `> Status: stub - filled in Phase N` banner so the file map is complete but no one mistakes stubs for finished docs.

## Acceptance criteria

- [ ] `git clone <repo> && ./Scripts/build-app.sh` succeeds on a Mac with the pinned Xcode version (real output, not "should work").
- [ ] Xcode project opens without warnings about missing files; empty app launches and shows a menu-bar stub without crashing.
- [ ] `AECBridge` static library compiles and `import AECBridge` resolves in Swift (even though it is a passthrough stub).
- [ ] `DSP/RingBuffer` has unit tests that pass locally and in CI (push/pop, overflow, underflow, wrap-around, concurrent SPSC smoke test).
- [ ] Both GitHub Actions workflows are green on `main`.
- [ ] No secret, certificate, or provisioning profile is committed. `.gitignore` covers `*.p12`, `*.pem`, `DerivedData/`, `build/`, `webrtc-checkout/`.
- [ ] `phases/README.md` status board flipped to DONE for Phase 0 with date, and any new pin (Xcode version, C++ standard) appended to `phases/DECISIONS.md`.

## Pitfalls

- Do not create the Xcode project on Windows and commit a broken `.pbxproj`. Create it on the Mac.
- Do not check a multi-GB `webrtc-checkout/` into the repo. Phase 4's script fetches it outside the repo.
- Do not add BlackHole as a submodule or copy its source. It is a dev dependency installed on the Mac only when Phase 6 starts.

## Next phase gate

Phase 1 may start only when all boxes above are checked with real command output. The gate is the build, not the docs.
