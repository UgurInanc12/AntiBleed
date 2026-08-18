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
