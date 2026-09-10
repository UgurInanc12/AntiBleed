# Anti-Bleed_mic: Decision Log

Status values: ACCEPTED (final), PROPOSED (awaiting Ugur's confirmation), SUPERSEDED (replaced by a later decision).
Newest decision at the bottom. Never delete entries; supersede with a new one.

## D-001: Product and virtual-device naming

- Status: ACCEPTED
- Context: PLAN chapters 1, 15. The product must expose a single virtual input that any Core Audio client can select.
- Decision: Product name `Anti-Bleed_mic` for the visible input device. Internal hidden writer device `Anti-Bleed_internal_writer`. Driver bundle `AntiBleed.driver`. No alternative names without a new decision.
- Consequence: All UI copy, driver Info.plist, and installer text use these exact identifiers. `kAudioDevicePropertyIsHidden` marks the writer as hidden.

## D-002: Primary platform and hardware target

- Status: ACCEPTED (PLAN chapters 5, 42)
- Context: Core Audio Process Tap (`CATapDescription` / `AudioHardwareCreateProcessTap`) requires macOS 14.2+. AEC3 tuning depends on real Apple Silicon hardware behavior.
- Decision: Primary target `macOS 14.2+`, first hardware validation on Apple Silicon. Intel Mac is a compatibility target after the core pipeline works. Do not add ARM-only code without justification.
- Consequence: CI runner is `macos-14` or newer. No effort to support <14.2 in v1. Older-macOS fallback via ScreenCaptureKit is deferred (not in v1).

## D-003: System-audio reference capture - Core Audio Process Tap

- Status: ACCEPTED (PLAN chapter 9)
- Context: Options were routing desktop audio through a third-party virtual cable vs Apple's native tap API. The tap API (14.2+) is the intended system path and avoids a mandatory third-party dependency.
- Decision: Primary reference capture is a private Core Audio Process Tap bound to the selected physical output device, via `CATapDescription` + `AudioHardwareCreateProcessTap` inside a private aggregate device (chapter 11.2). Own process and the internal writer are excluded from the tap where appropriate; normal speaker output is not muted.
- Consequence: ScreenCaptureKit fallback is not implemented in v1. Docs record why the tap was chosen; code comments cite `developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps`.

## D-004: Virtual device implementation - Audio Server Plug-in

- Status: ACCEPTED (PLAN chapters 15, 41)
- Context: AudioDriverKit sounds newer but Apple documents it for physical device drivers. Audio Server Plug-in is documented as the preferred mechanism for virtual devices.
- Decision: Production virtual device is a Core Audio Audio Server Plug-in (`.driver` in `/Library/Audio/Plug-Ins/HAL`). Not AudioDriverKit.
- Consequence: Driver build follows `developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in`. Sample AudioServerPlugIn code is the reference, not AudioDriverKit samples.

## D-005: Two-device driver topology

- Status: ACCEPTED (PLAN chapter 15.2)
- Decision: The plug-in exposes two devices sharing a driver-side ring buffer:
  - `Anti-Bleed_mic` - visible, input-only, selected by users in Discord/Zoom.
  - `Anti-Bleed_internal_writer` - hidden (`kAudioDevicePropertyIsHidden`), output-only, discovered by UID by the app and fed the cleaned PCM.
  ```
  Anti-Bleed app -> Anti-Bleed_internal_writer [hidden out] -> shared ring -> Anti-Bleed_mic [visible in] -> Discord
  ```
- Consequence: No external IPC between app and driver, no aggregate/multi-output device for users to configure, no visible virtual output polluting device pickers.

## D-006: AEC engine - WebRTC APM / AEC3, pinned revision

- Status: ACCEPTED (PLAN chapters 4, 12, 33)
- Decision: AEC engine is WebRTC Audio Processing Module / Echo Canceller 3 (C++, via Objective-C++ bridge). Default config: `AEC=ON, NS=OFF, AGC=OFF, transient=OFF, VAD=diagnostics only`. Pin an exact `WEBRTC_REVISION` commit SHA; never float on `main` in production. Do not check a multi-GB WebRTC checkout into the repo - fetch in CI / on the Mac.
- Consequence: Build automation (`Scripts/build-webrtc.sh`) fetches `depot_tools` -> syncs the pinned revision -> GN/Ninja builds APM targets -> archives static libs + NOTICE files. CI caches the artifact.

## D-007: Canonical signal format

- Status: ACCEPTED (PLAN chapter 8)
- Decision: One canonical internal format:
  ```
  48,000 Hz / Float32 / 10 ms frames (480 samples/channel) / mono AEC paths
  ```
  Stereo system output is downmixed to mono only for the AEC reference; user playback is untouched. Additional virtual-mic formats (44.1 kHz, stereo duplicate) only if compatibility tests justify them.
- Consequence: All converters, resamplers, and frame assemblers target this format. Resampling preserves continuous state and accounts for resampler delay in sync metrics.

## D-008: Hard invariant - never direct-subtract render from mic

- Status: ACCEPTED (PLAN chapters 2.1, 13.1, 41)
- Decision: `virtual_output = rawMic - rawRender` is forbidden. The acoustic path is `h(t) * r(t)` with latency, frequency response, reflections, volume, drift, and nonlinearity - only an adaptive AEC can cancel it. Selectable outputs are strictly: `raw mic` / `AEC-processed mic` / controlled crossfade / `silence` (on fatal failure). Never an inverted render signal.
- Consequence: Regression test Case H (render active, no coupling) must verify no render-correlated component appears in output. Any violation is a P0 bug.

## D-009: Development model - Windows can do everything except the Mac build

- Status: ACCEPTED
- Context: Primary workstation is Windows 11 (this machine). The final macOS app cannot be compiled or acoustically validated from Windows.
- Decision:
  - Windows (this machine): repo management, architecture/docs, DSP test-vector generation, Python offline harness (pytest), C++ unit tests that are platform-independent, agent coding, CI configuration. No new software beyond git + Python/uv required to start.
  - Mac (physical, 14.2+): Xcode/SDK, Swift + driver compilation, Core Audio permission tests, physical speaker-to-mic echo tests, Discord integration, code signing/notarization/installer validation.
  - CI: GitHub Actions `macos-14` runner validates compilation + unit tests but never replaces hardware acoustic tests.
- Consequence: Offline harness is Python so it runs on Windows without Xcode. C++ DSP library is structured to be testable on any OS.

## D-010: BlackHole is MVP-only, with licensing guard

- Status: ACCEPTED (PLAN chapters 15, 16)
- Decision: BlackHole 2ch may be used as an installed dev dependency to prove the DSP path before the custom driver exists (Phase 6). It must not remain a mandatory runtime dependency in the finished product and its GPL-3.0 source must not be copied into a proprietary release without resolving licensing.
- Consequence: Phase 8-9 explicitly remove BlackHole from the product path. `Docs/Driver.md` and phase docs carry the warning verbatim.

## D-011: Timing - private aggregate device as primary clock source

- Status: ACCEPTED (PLAN chapter 11)
- Decision: Prefer a private Core Audio aggregate device containing the selected mic subdevice + the system tap subtap. Apple's docs guarantee clock synchronization of subdevices/subtaps inside an aggregate during I/O. Start with `tap = clock reference, mic = drift compensated` but validate experimentally and support switching the master without hard-coding. Layer additional sync: Core Audio timestamps (`mHostTime`/`mSampleTime`/`mRateScalar`) -> ring buffers -> AEC3 delay estimator -> drift telemetry.
- Consequence: `AudioSynchronizer` tracks `delay_ms`, `delay_median`, `delay_stddev`, buffer skew, under/overruns. No fixed 50/80/100 ms delay as the solution.

## D-012: Safety priority - false bypass beats false cancellation

- Status: ACCEPTED (PLAN chapter 13)
- Decision: Failure mode is `speaker bleed returns temporarily`, never `user voice destroyed or inverted desktop injected`. State machine: `STOPPED / BYPASS / PROBING / LEARNING / ACTIVE / DEGRADED / ERROR`. Transitions use render-activity detection + acoustic-coupling detector (correlation/coherence + AEC3 `delay`/`ERL`/`ERLE`/`divergent_filter_fraction` etc.) + hysteresis (500 ms enter, 500-1500 ms exit) + 50-150 ms crossfades. AEC may keep adapting while output is BYPASS.
- Consequence: Every route change (output or mic) crossfades to raw mic, tears down old tap, resets AEC, and re-enters PROBING/LEARNING before reactivating.

## D-013: Telemetry and logging - never log audio

- Status: ACCEPTED (PLAN chapters 38, 39)
- Decision: All processing is local. No cloud API, no speech-to-text, no analytics containing audio, no hidden recording. Normal logs: device names, state transitions, permission state, AEC metrics, queue stats, error codes - rate-limited, never per-10ms-frame. No PCM, no transcripts, no audio contents in logs. Debug WAV dumps are opt-in, developer-only, with a visible indicator and a defined deletion path.
- Consequence: CI or release builds must not enable debug dumps by default.

## D-014: Versioning and reproducibility

- Status: ACCEPTED (PLAN chapter 34)
- Decision: Pin and surface: Xcode major version (in CI), macOS deployment target, `WEBRTC_REVISION` SHA, compiler settings, driver ABI/version, DSP config schema. Diagnostics surface `Anti-Bleed version / Git commit / WebRTC revision / Driver version / macOS version / CPU arch`.
- Consequence: Every release artifact is traceable to these pins.

## D-015: AEC3 sourced from webrtc-audio-processing (Meson), not a Chromium checkout

- Status: ACCEPTED (supersedes the fetch mechanism in D-006; engine and defaults unchanged)
- Context: The raw WebRTC checkout needs depot_tools/GN and a multi-GB sync, and cannot be built on the Windows workstation used for development. PulseAudio maintains `webrtc-audio-processing`, a standalone packaging of upstream WebRTC's Audio Processing Module including AEC3, buildable with Meson on macOS/Linux/Windows.
- Decision: Pin `webrtc-audio-processing` tag `v2.1` (commit `846fe90a289f58b7c9303a635142aa2c7caa93e5`) in `WEBRTC_REVISION`. `Scripts/build-webrtc.sh` refuses to build any other commit. Built with `cpp_std=c++20`, static, into `build/webrtc`. License/NOTICE files staged into `build/webrtc/licenses` and shipped in the app bundle.
- Consequence: Real AEC3 runs in the offline harness on Windows (`Tests/test_aec3_offline.py`, `Tests/test_pipeline_integration.py`). Measured on synthetic rooms: 43 to 56 dB echo attenuation, delays 10 to 200 ms found within 4 ms, 9 ms processing latency.

## D-016: Swift core is platform-independent and unit-tested on Windows

- Status: ACCEPTED
- Decision: All decision logic (engine, safety FSM, coupling detector, synchronizer, frame assembler, crossfade, rings) lives in `AntiBleedApp/Core` (SwiftPM target `AntiBleedCore`) with no Core Audio/SwiftUI imports, plus C rings in `AntiBleedApp/Realtime`. Core Audio code is isolated in `AntiBleedApp/Audio` under `#if canImport(CoreAudio)`. `Scripts/swift-test-windows.cmd` runs the 43 XCTest cases with the winget Swift 6.3 toolchain.
- Consequence: A Mac is required only for compiling `AntiBleedAudio`/`AntiBleedApp`/the HAL driver and for acoustic validation; every other regression is caught on Windows/CI.

## D-017: Capture topology is one private aggregate (mic sub-device + process tap)

- Status: ACCEPTED (implements D-003/D-011)
- Decision: `AggregateCapture` creates a `CATapDescription` (private, unmuted, stereo mixdown, excluding our own process) and one private aggregate device containing the selected mic as main sub-device (drift compensated) and the tap in `kAudioAggregateDeviceTapListKey`. One IOProc receives both, so every callback carries a mic block and a render block for the same instant. The IOProc only downmixes to mono and pushes into `abm_ring` (no DSP).
- Consequence: `AudioSynchronizer` sees near-zero skew inside the aggregate and acts as a guard, not as the primary alignment mechanism. Headphones mode is `outputDeviceUID == nil` (no tap, render channel silent, FSM stays BYPASS).

## D-018: Coupling detector is decimated, hint-centred and ERLE-aware

- Status: ACCEPTED (refines D-012 detector design)
- Context: A per-frame full-band correlation over 480 samples could not see acoustic delays beyond 5 ms and scored 0.2 on a real 45 ms echo path.
- Decision: The detector keeps a 650 ms history decimated 8x (6 kHz), correlates a 400 ms window over 0 to 250 ms of lag (1 ms steps), narrows to +-15 ms around the AEC3 delay estimate once available, and weights correlation 0.45, ERLE 0.35, lag stability 0.20, multiplied by AEC health. Evaluated every 100 ms.
- Consequence: Measured 0.94 correlation at the true 45 ms lag with score 1.0 on the coupled case and score 0.0 on the headphones case, using the real AEC3 output statistics. Swift and Python mirrors must stay in sync (`AntiBleedApp/Core/CouplingDetector.swift`, `Tests/dsp/coupling_detector.py`).

## D-019: License

- Status: ACCEPTED
- Decision: Anti-Bleed_mic is released under Apache-2.0 (Copyright 2026 Ugur Inanc). Third-party notices in NOTICE. No GPL code is present (BlackHole was never used, D-010).
- Consequence: `Scripts/package.sh` ships LICENSE, NOTICE and the WebRTC/abseil license texts inside the app bundle.

## D-020: Continuous operation - far-end silence never switches the exposed signal

- Status: ACCEPTED (refines D-012)
- Context: The first Mac build showed the product behaving as `Bypass` while quiet, then `Learning`, then processing, and the audio audibly skipped on each pass. Two causes were measured with the real AEC3 (webrtc-audio-processing 2.1, `build/aec/Release/aec_offline.exe`):
  1. The AEC output lags its own input by a constant 430 samples (8.96 ms at 48 kHz; identical with render silent, render active without coupling, and during double talk, and stable across a stream). The FSM exposed the undelayed raw mic in BYPASS and the AEC output in ACTIVE, so every transition spliced two instants ~9 ms apart, and the 100 ms crossfade mixed a signal with a time-shifted copy of itself.
  2. `ACTIVE -> BYPASS on render inactive` fired on every conversational pause, although a silent far end leaves the AEC transparent: measured over an 8 s pause the AEC output matched the raw mic within 0.0 dB at 0.985 correlation. The rule protected nothing and generated the transitions.
- Decision:
  - The raw candidate is delayed to the canceller's own latency (`DelayLine`), measured at startup by `EchoCancellerLatency.measure` with a 100 ms internal noise burst against a silent render (0.1 s already resolves the lag exactly; the AEC is reset afterwards). Both FSM candidates therefore describe the same instant and a switch is a gain change, not a time jump.
  - Far-end silence no longer leaves ACTIVE or LEARNING. Coupling is only re-judged while the far end actually plays; during silence the score decays for lack of evidence, not for lack of an echo path. ACTIVE has NO silence timeout (`activeSilenceGraceFrames = 0`): once processing is running it keeps running until a real hazard or the user stops it. LEARNING keeps a 5 s bound because it has not yet proven a coupling path.
  - The hazards that BYPASS exists for are unchanged and still act during silence where they apply: coupling lost while the far end plays (headphones), filter divergence, and route change.
  - At the app level, while macOS is not playing through the selected reference output the engine holds BYPASS and passes the raw microphone through (`AppState.pauseWhenOutputNotDefault` -> `AntiBleedPipeline.setReferenceOutputActive`, on by default), re-engaging automatically when that output is default again. This is the deliberate answer to the headphones case, where AEC3 attenuates the near-end voice by roughly 6 dB (`Tests/test_aec3_offline.py::test_case_h_...`). The pipeline is NOT stopped: the virtual mic is a live input in someone's call and must never go silent because the user plugged in headphones. The AEC keeps adapting so re-selecting the speakers converges immediately.
  - `aecAvailable == false` is now an exit condition from ACTIVE/LEARNING/PROBING, crossfading back to raw. Previously the flag only blocked BYPASS -> PROBING, so a canceller that became unusable while ACTIVE kept its processed output exposed.
- Consequence: A pause produces zero state transitions and zero source switches (`Tests/test_pipeline_integration.py::test_scenario_6_...`). Alignment is verified in `test_scenario_7_...` (aligned correlation > 0.95 versus 0.55 unaligned) and in `PathAlignmentTests`. The virtual mic gains 9 ms of latency in BYPASS, which is the price of a seamless switch and stays well inside the PLAN 30 latency budget. Swift and Python FSM mirrors must stay in sync.

