# Anti-Bleed_mic: Architecture

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 3, 7, 9, 11, 12, 15, 19, 20, 34.
> Status: stub - filled incrementally phase-by-phase. Phase 0 owns this file's skeleton; later phases fill their sections.

## 1. Purpose

Anti-Bleed_mic is a macOS 14.2+ virtual microphone that removes acoustic speaker bleed from the physical microphone while preserving the user's voice. It is an adaptive Acoustic Echo Cancellation (AEC) product, not a generic noise suppressor.

## 2. Signal model

```
r(t)  - digital audio sent to the physical output
h(t)  - acoustic transfer path speaker -> room -> microphone (convolution)
s(t)  - user's wanted near-end voice
n(t)  - ambient/room noise
m(t)  - raw microphone capture

m(t) = s(t) + n(t) + h(t) * r(t)
target clean(t) ≈ s(t) + n(t)  (estimate and subtract h(t)*r(t))
```

Hard invariant: never `clean = mic - systemAudio`. The path `h(t)` includes DAC/ADC latency, buffering, propagation, speaker/mic frequency response, reflections, volume, drift, and nonlinearity - only an adaptive AEC (WebRTC AEC3) can estimate it.

## 3. High-level block diagram

```
                    SELECTED PHYSICAL OUTPUT
                              |
                 +------------+------------+
                 |                         |
                 v                         v
            loudspeaker               Core Audio Process Tap
                 |                         |
                 | acoustic echo           | exact digital reference (CATapDescription)
                 v                         |
          physical microphone              |
                 |                         |
                 +-----------+-------------+
                             |
                      synchronized frames (private aggregate device + timestamps)
                             |
                             v
                       WebRTC AEC3 / APM
                       ProcessReverseStream(render) -> ProcessStream(mic)
                             |
                             v
                      safety state machine
                 BYPASS / PROBING / LEARNING / ACTIVE / DEGRADED / ERROR
                             |
              +--------------+--------------+
              |                             |
        no echo path                   real echo path
              |                             |
              v                             v
          raw mic                       AEC output
              |                             |
              +--------------+--------------+
                             |
                             v
              Anti-Bleed_internal_writer  (hidden output, kAudioDevicePropertyIsHidden)
                             |
                             v
                      driver shared ring buffer (bounded, lock-free SPSC)
                             |
                             v
                     Anti-Bleed_mic  (visible input, selected in Discord/Zoom)
                             |
                             v
                          Discord etc.
```

## 4. Technology choices (D-003 / D-004 / D-006)

| Subsystem | Choice | Why |
|-----------|--------|-----|
| App language | Swift + SwiftUI (menu bar) | Native macOS UI, Core Audio interop |
| AEC engine | WebRTC APM / AEC3 (C++, pinned WEBRTC_REVISION) | Industry reference for near-end/far-end AEC; handles double-talk |
| System reference | Core Audio Process Tap (`CATapDescription`, 14.2+) | Apple's intended API; avoids third-party virtual cable |
| Virtual device | Audio Server Plug-in (`AntiBleed.driver`) | Apple's documented path for virtual devices (not AudioDriverKit) |
| Clock sync | Private aggregate device (mic subdevice + tap subtap) | Apple guarantees clock sync of constituents during I/O |
| Bridge | Objective-C++ (`AECBridge.h/.mm`) | Swift <-> C++ boundary |

## 5. Repository map (PLAN chapter 7)

```
AntiBleed/
├── AntiBleedApp/App/        - Swift app, AppState, Permissions
├── AntiBleedApp/UI/         - MenuBarView, DeviceSelectorView, DiagnosticsView, SettingsView
├── AntiBleedApp/Audio/      - DeviceManager, MicrophoneCapture, SystemAudioTap,
│                              AggregateDeviceManager, AudioSynchronizer, FormatConverter,
│                              AntiBleedPipeline, VirtualMicWriter
├── AECBridge/               - C++ wrapper (AECProcessor) + ObjC++ glue (AECBridge)
├── AntiBleedDriver/         - Audio Server Plug-in (visible + hidden devices, shared ring)
├── DSP/                     - RingBuffer, Resampler, SignalMetrics, CouplingDetector, CrossFade
├── Tests/                   - DSPTests / AECTests / SynchronizationTests / DriverTests / OfflineFixtures
├── Scripts/                 - bootstrap-macos.sh, build-webrtc.sh, build-app.sh, install-driver.sh, ...
├── phases/                  - ordered execution plan (this development plan)
└── Docs/                    - this file + DSP/Driver/Permissions/Testing/Distribution
```

## 6. Canonical signal format (D-007)

```
Sample rate:          48,000 Hz
Sample type:          Float32
Frame size:           10 ms (480 samples/channel)
Capture channels:     1 mono
Render channels:      1 mono (stereo reference downmixed (L+R)/2 for AEC only)
Default APM config:   AEC ON, NS OFF, AGC OFF, transient OFF
```

Additional virtual-mic formats (44.1 kHz, stereo duplicate) only if compatibility tests justify them.

## 7. Threading and real-time rules (PLAN 19)

```
Core Audio callbacks (mic + tap)          DSP worker thread               Main thread (UI)
─────────────────────────────            ──────────────────              ─────────────────
Copy Float32 block                       Pull timestamp-aligned pairs    @Published state,
attach AudioTimeStamp (host/sample/rate) assemble 480 frames            meters (30 Hz),
push into lock-free SPSC ring            ProcessReverseStream/Stream     pickers, diagnostics
return immediately                       crossfade / gate output
                                         push to VirtualWriterRing
No malloc, no blocking mutex, no I/O, no UI work, no JSON in any audio thread.
```

AEC runs on the dedicated DSP thread, not in callbacks and not on the main thread.

## 8. Timing and synchronization (PLAN 11)

Layered:

1. **Aggregate clock sync** - private aggregate device synchronizes mic + tap (preferred).
2. **Timestamp alignment** - `mHostTime`/`mSampleTime`/`mRateScalar` preserved per block; `AudioSynchronizer` pairs by `hostTime` within tolerance, drops stale frames, tracks `bufferSkew`.
3. **AEC3 delay estimator** - refines acoustic delay internally.
4. **Telemetry** - `delayMs`, `delayMedian`, `delayStddev`, `bufferSkew`, `under/overruns`, `drift ppm`.

Clock master default: tap (output-derived) as reference, mic drift-compensated - but both options are measured and selectable; never hard-code without data.

## 9. Driver topology (PLAN 15, D-005)

```
Anti-Bleed app --Core Audio writes--> Anti-Bleed_internal_writer [hidden, output]
                                            |
                                     shared driver SPSC ring
                                            |
Anti-Bleed_mic [visible, input] <--Core Audio reads--+
       |
       v
    Discord
```

- `AntiBleed.driver` at `/Library/Audio/Plug-Ins/HAL/`
- Visible: `Anti-Bleed_mic` (`com.antibleed.mic`, input-only)
- Hidden: `Anti-Bleed_internal_writer` (`com.antibleed.writer`, output-only, `kAudioDevicePropertyIsHidden`)
- Underflow -> silence (never replay/uninitialized), overrun -> drop oldest (newest wins), counters for diagnostics.

## 10. Safety state machine (PLAN 13, D-012)

```
STOPPED -> BYPASS -> PROBING -> LEARNING -> ACTIVE
                      ^             |          |
                      +-------------+----------+
                      |  divergence / route change
                      v
                   DEGRADED -> BYPASS
ANY -> ERROR -> STOPPED (on fatal I/O failure)
```

- Render activity detector (RMS + hangover 200-500 ms, hysteresis 500-1500 ms) gates whether there is anything to cancel.
- Coupling detector ensembles correlation/coherence + AEC3 `delay`/`ERL`/`ERLE`/`divergent_filter_fraction`; no single metric decides alone. Headphone transport is a prior, not a decision.
- Crossfade 50-150 ms on every transition - no clicks.
- Failure mode is "bleed returns," never "voice destroyed or inverted render injected."

## 11. Versioning (PLAN 34, D-014)

Pinned: Xcode major, macOS deployment target (14.2), `WEBRTC_REVISION` SHA, `CMAKE_CXX_STANDARD`/`SWIFT_VERSION`, driver ABI/version, DSP config schema. Surfaced together in Diagnostics: `app / git / WebRTC / driver / macOS / arch`.

## 12. References

- System taps: `developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps`
- Aggregate: `developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice`
- Virtual device: `developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in`
- WebRTC APM: `webrtc.googlesource.com/src/.../modules/audio_processing/g3doc/audio_processing_module.md`
- This repo's phase docs: `phases/PHASE-*.md` (execution order, acceptance criteria)
