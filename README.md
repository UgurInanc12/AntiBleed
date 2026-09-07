# Anti-Bleed_mic

> macOS Acoustic Echo Cancellation virtual microphone - remove speaker bleed from your mic, keep your voice.
> **Status:** Builds end to end on macOS CI (APM, AECBridge, AntiBleed.driver, app; 43 Swift + 84 Python tests). Remaining: install and validate on real Mac hardware (see Docs/Testing.md section 5).
> **Primary target:** macOS 14.2+ (Apple Silicon first, Intel after)
> **Virtual device:** `Anti-Bleed_mic` (Core Audio Audio Server Plug-in)
> **AEC engine:** WebRTC APM / AEC3 (local-only, real-time)
> **Reference capture:** Core Audio Process Tap (`CATapDescription`)

## What it does

```
YouTube / Discord / game audio
            |
            v
       Mac speakers
            |
            |  acoustic path through the room
            v
     physical microphone
            |
            X  remove only the speaker-originated component
            |
            v
      Anti-Bleed_mic  (virtual input device)
            |
            v
          Discord / Zoom / any Core Audio input client
```

`Anti-Bleed_mic` exposes a cleaned microphone stream:

* keeps: your voice, keyboard/room noise the mic genuinely captured
* removes: Discord friends' voices, YouTube/game/music audio that leaked from the Mac speakers back into the mic

This is **acoustic echo cancellation**, not generic noise suppression or AI voice filtering. The default signal path enables AEC only; NS/AGC are off.

Hard rule from the spec: never `clean = mic - system_audio`. The acoustic path is a filtered, delayed, reverberated convolution `h(t) * r(t)` - only an adaptive AEC (AEC3) can estimate and cancel it.

## Quick start

macOS 14.2+ (build + run):

```text
Scripts/bootstrap-macos.sh          # Xcode CLT, cmake, meson, ninja, python venv
Scripts/build-app.sh release        # WebRTC AEC3 -> AECBridge -> AntiBleed.driver -> app, all tests
sudo Scripts/install-driver.sh      # Anti-Bleed_mic appears as an input device
Scripts/package.sh release          # build/AntiBleed.app (signed if DEVELOPER_ID is set)
open build/AntiBleed.app            # menu bar icon -> pick mic + speakers -> Start
```

Then select **Anti-Bleed_mic** as the microphone in Discord/Zoom. Speaker audio that reaches your mic is removed; with headphones the app stays in bypass and passes your mic through untouched.

Windows (development, no Mac): `Docs/Testing.md` section 2. Real AEC3 offline tests and the Swift core suite run here.

## How it decides (short)

```
speakers playing? --no--> BYPASS (raw mic)
      | yes
does the speaker signal actually show up in the mic (correlation + AEC3 delay/ERLE)?
      | no  -> BYPASS/PROBING (raw mic)   <- headphones case
      | yes -> LEARNING -> ACTIVE (AEC3 output, 100 ms crossfade)
filter diverges / coupling lost / device change -> back to raw mic first, then re-learn
```


## Repository layout (target)

```
AntiBleed/
├── README.md
├── ANTI_BLEED_MIC_PLAN.md      # frozen master spec (48 chapters)
├── LICENSE
├── .gitignore
├── .github/
│   └── workflows/
│       ├── macos-build.yml     # Swift + C++ + driver on macOS runner
│       └── unit-tests.yml      # platform-independent DSP tests (any OS)
├── phases/                     # ordered execution plan (this repo's dev plan)
│   ├── README.md               # status board
│   ├── DECISIONS.md            # decision log
│   └── PHASE-0..11-*.md
├── Docs/
│   ├── Architecture.md
│   ├── DSP.md
│   ├── Driver.md
│   ├── Permissions.md
│   ├── Testing.md
│   └── Distribution.md
├── AntiBleedApp/
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
│   └── build scripts
├── DSP/
│   ├── RingBuffer.hpp
│   ├── Resampler.*
│   ├── SignalMetrics.*
│   ├── CouplingDetector.*
│   └── CrossFade.*
├── Tests/
│   ├── DSPTests/
│   ├── AECTests/
│   ├── SynchronizationTests/
│   ├── DriverTests/
│   ├── OfflineFixtures/
│   └── HardwareTestProtocol.md
└── Scripts/
    ├── bootstrap-macos.sh
    ├── build-webrtc.sh
    ├── build-app.sh
    ├── install-driver.sh
    ├── uninstall-driver.sh
    └── package.sh
```

## Signal constants

```
Sample rate:          48,000 Hz
Sample type:          Float32
Frame size:           10 ms  (480 samples/channel)
AEC capture channels: 1 (mono)
AEC render channels:  1 (mono downmix of L+R reference)
```

## Development model

| Machine | Role |
|---------|------|
| **Windows (this workstation)** | Repo/DOCS, C++ unit tests, DSP test-vector generation, agent coding, CI config. No Xcode - cannot compile the macOS app/driver. |
| **Mac (physical, 14.2+)** | Xcode, Core Audio, driver build, permission testing, real speaker-to-mic echo tests, signing/notarization. |
| **GitHub Actions (macOS runner)** | Compiles Swift/C++/driver, runs offline DSP tests. Cannot replace acoustic hardware tests. |

All artifacts are English: code, identifiers, comments, commits, docs.

## Phases at a glance

| Phase | Scope | Depends on |
|-------|-------|------------|
| 0 | Repo + build skeleton (no DSP) | - |
| 1 | Raw microphone capture (unprocessed) | 0 |
| 2 | Core Audio system tap (render reference) | 1 |
| 3 | Timing / private aggregate device | 2 |
| 4 | Offline WebRTC AEC3 (synthetic tests) | 3 |
| 5 | Live AEC (real speaker bleed) | 4 |
| 6 | BlackHole MVP → Discord end-to-end | 5 |
| 7 | Safety state machine (BYPASS/PROBING/LEARNING/ACTIVE...) | 6 |
| 8 | Custom `Anti-Bleed_mic` driver | 7 |
| 9 | Remove BlackHole dependency | 8 |
| 10 | Product UI + recovery | 9 |
| 11 | Packaging, signing, notarization | 10 |

Detailed plan: `phases/README.md`. Master spec: `ANTI_BLEED_MIC_PLAN.md` chapters 1-48.

## Key invariants

* Never `virtual_output = rawMic - rawRender`.
* Selectable outputs are only: `raw mic` / `AEC-processed mic` / controlled crossfade / `silence`. Never an inverted render.
* Real-time callbacks: no malloc, no blocking mutex, no I/O, no UI work. Copy → timestamp → push to lock-free ring → return.
* Safety gate: if there is no stable acoustic coupling (headphones, muted speaker), output is raw mic - never inject render.
* All audio stays local. No cloud, no upload.

## Getting started (from Windows)

```bash
# clone and inspect the plan
git clone <repo-url> && cd AntiBleed
cat ANTI_BLEED_MIC_PLAN.md
cat phases/README.md

# offline DSP harness (Python, no Mac required)
uv venv && uv pip install -r Tests/requirements.txt
uv run pytest Tests/
```

Mac bootstrap (on the Mac):

```bash
./Scripts/bootstrap-macos.sh   # Xcode CLT, depot_tools, GN/Ninja
./Scripts/build-webrtc.sh      # pinned WEBRTC_REVISION
./Scripts/build-app.sh
```

## Docs

* `ANTI_BLEED_MIC_PLAN.md` - frozen master spec (source of truth)
* `phases/README.md` - execution status board
* `phases/DECISIONS.md` - decision log
* `phases/PHASE-*.md` - per-phase build/test instructions
* `Docs/*.md` - architecture/DSP/driver/permissions/testing/distribution deep dives (filled phase-by-phase)

## License

TBD - note: BlackHole is GPL-3.0. Do not copy its source into a proprietary release without resolving licensing (see PLAN chapter 16.1).
