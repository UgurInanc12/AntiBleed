# Anti-Bleed_mic — macOS Acoustic Echo Cancellation Virtual Microphone

**Status:** Implementation plan  
**Primary target:** macOS 14.2+  
**Primary use case:** Discord and other voice applications using Mac speakers without feeding speaker audio back through the microphone  
**Virtual microphone name:** `Anti-Bleed_mic`  
**Processing model:** Local-only, real-time, reference-based Acoustic Echo Cancellation (AEC)  
**Primary AEC engine:** WebRTC Audio Processing Module / AEC3  
**Primary system-audio capture:** Core Audio Process Tap  
**Primary virtual-device implementation:** Core Audio Audio Server Plug-in  

---

## 1. Project objective

The application must create a virtual microphone named:

```text
Anti-Bleed_mic
```

The user selects `Anti-Bleed_mic` as the microphone in Discord, Zoom, games, browsers, recording applications, or any other application that accepts a Core Audio input device.

The purpose is **not generic noise suppression**.

The purpose is specifically to remove audio that originated from the Mac's output path and was then acoustically re-captured by the physical microphone.

Example:

```text
YouTube / Discord / game audio
            |
            v
       Mac speakers
            |
            | acoustic path through the room
            v
     physical microphone
            |
            X  remove only the speaker-originated component
            |
            v
      Anti-Bleed_mic
            |
            v
          Discord
```

The final virtual microphone should contain:

- the user's voice,
- keyboard / room / environmental sounds that the physical microphone genuinely captured,
- other non-speaker-originated microphone content,

while suppressing:

- Discord friends' voices coming from the Mac speakers,
- YouTube/video audio coming from the Mac speakers,
- game/movie/music audio coming from the Mac speakers,
- any other sound that originated from the selected system output and leaked acoustically back into the selected microphone.

The project must avoid turning into a general AI voice filter. Noise suppression, AGC, dereverberation, voice isolation, and speech enhancement are **out of scope for the default signal path**.

---

# 2. Correct signal model

Let:

- `r(t)` = digital audio sent to the physical output device,
- `s(t)` = the user's real near-end voice / wanted microphone signal,
- `n(t)` = unrelated ambient noise,
- `h(t)` = the physical acoustic transfer path from speaker to microphone,
- `m(t)` = raw microphone capture.

The microphone approximately receives:

```text
m(t) = s(t) + n(t) + h(t) * r(t)
```

where `*` represents convolution.

The target is:

```text
clean(t) ≈ s(t) + n(t)
```

The application must estimate the acoustic echo path `h(t)` and cancel:

```text
h(t) * r(t)
```

from the microphone.

## 2.1 Do NOT directly subtract desktop PCM from microphone PCM

This is a hard architectural rule.

Never implement:

```text
clean = mic - system_audio
```

or:

```text
clean = mic + (-system_audio)
```

The audio reaching the microphone is not a sample-for-sample copy of the operating-system output.

The acoustic path modifies it through:

- speaker/DAC latency,
- microphone/ADC latency,
- operating-system buffering,
- sound propagation,
- speaker frequency response,
- microphone frequency response,
- room reflections,
- reverberation,
- amplitude changes,
- device volume,
- automatic hardware behavior,
- clock drift,
- possible loudspeaker nonlinearity.

Therefore the correct algorithm is an **adaptive acoustic echo canceller**, not simple waveform subtraction.

WebRTC AEC3 is designed for this exact near-end/far-end problem.

---

# 3. High-level architecture

```text
                       macOS AUDIO OUTPUT
                              |
                              |
                +-------------+-------------+
                |                           |
                v                           v
        Physical speaker              Core Audio Tap
                                             |
                                             |
                                             v
                                      Far-end reference
                                             |
                                             |
Physical microphone                          |
        |                                    |
        v                                    |
Raw mic capture                              |
        |                                    |
        +----------------+-------------------+
                         |
                         v
                Sync / clock layer
                         |
                         v
                 WebRTC AEC3 / APM
                         |
                  Clean microphone
                         |
                         v
                 Safety / bypass gate
                         |
                         v
                 Virtual-device writer
                         |
                         v
              hidden Anti-Bleed writer
                         |
                         v
          shared virtual-driver ring buffer
                         |
                         v
                  Anti-Bleed_mic
                         |
                         v
               Discord / Zoom / etc.
```

---

# 4. Recommended technology stack

## Application

- Swift
- SwiftUI for menu-bar/settings UI
- Core Audio
- AVFAudio where useful
- small Objective-C++ bridge for C++ WebRTC integration

## System-output capture

Primary:

- Core Audio Process Tap
- `CATapDescription`
- `AudioHardwareCreateProcessTap`
- private aggregate device

Targeting macOS 14.2+ allows us to use Apple's native Core Audio tap API instead of routing desktop audio through another third-party virtual cable.

Fallback for an older-macOS version can later use ScreenCaptureKit, but it is not part of the first implementation.

## Raw microphone capture

Preferred production path:

- Core Audio AUHAL / Hardware Abstraction Layer

Acceptable initial path:

- `AVAudioEngine.inputNode`

If `AVAudioEngine` is used, voice processing must be explicitly disabled and verified:

```text
setVoiceProcessingEnabled(false)
```

The input signal must not already contain Apple's echo cancellation / Voice Processing / Voice Isolation.

## Acoustic echo cancellation

- WebRTC Audio Processing Module
- Echo Canceller 3 / AEC3
- C++

Default processing configuration:

```text
AEC:               ON
Noise suppression: OFF
AGC:               OFF
Voice detection:   optional diagnostics only
Transient filter:  OFF
```

AEC should be the only signal-altering feature enabled by default.

## Virtual microphone

Production:

- Core Audio Audio Server Plug-in
- custom `.driver`
- visible input-only device named `Anti-Bleed_mic`
- hidden output-only internal writer device

Development/MVP fallback:

- BlackHole 2ch

BlackHole is useful for proving the DSP pipeline before our own driver exists, but it should not remain a mandatory runtime dependency in the finished application.

---

# 5. Minimum supported platform

Recommended initial target:

```text
macOS 14.2+
```

Reason:

Apple's Core Audio tap sample requires macOS 14.2 or later.

Initial CPU targets:

```text
Apple Silicon: required for first hardware validation
Intel Mac:     compatibility target after the core pipeline works
```

Do not block the architecture on Intel support, but avoid unnecessary ARM-only code.

---

# 6. Development machines and required software

## 6.1 Windows development machine

A Windows PC can be used for:

- repository management,
- architecture work,
- documentation,
- most C++ unit tests,
- DSP test-vector generation,
- Hermes/Codex/other agentic coding,
- CI configuration,
- non-Apple-specific library code.

However, the final macOS application cannot be fully compiled or validated from Windows alone.

## 6.2 macOS build/test machine

A real Mac is required for:

- Xcode,
- macOS SDK,
- Core Audio APIs,
- Swift/macOS application compilation,
- Audio Server Plug-in compilation,
- microphone permission testing,
- system-audio-capture permission testing,
- physical speaker-to-microphone echo testing,
- virtual-device enumeration,
- Discord integration testing,
- code signing,
- notarization,
- installer validation.

## 6.3 Required developer tools

Install on Mac:

- latest stable Xcode compatible with target macOS,
- Xcode Command Line Tools,
- Git,
- optional Homebrew,
- Chromium `depot_tools` if building WebRTC directly,
- GN/Ninja through the WebRTC build toolchain,
- Audio MIDI Setup (ships with macOS).

Optional during DSP MVP:

- BlackHole 2ch.

## 6.4 Hermes Agent

Hermes is optional.

No special Hermes runtime is required by the product.

If Hermes is used as the implementation agent, it should operate against this repository and this plan, while actual macOS builds are performed on:

- the physical Mac,
- and/or a GitHub Actions macOS runner.

A CI runner can validate compilation and unit tests but cannot replace real acoustic testing with an actual Mac speaker and microphone.

---

# 7. Repository layout

Recommended structure:

```text
AntiBleed/
├── README.md
├── PLAN.md
├── LICENSE
├── .gitignore
├── .github/
│   └── workflows/
│       ├── macos-build.yml
│       └── unit-tests.yml
│
├── AntiBleedApp/
│   ├── App/
│   │   ├── AntiBleedApp.swift
│   │   ├── AppState.swift
│   │   └── Permissions.swift
│   │
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   ├── DeviceSelectorView.swift
│   │   ├── DiagnosticsView.swift
│   │   └── SettingsView.swift
│   │
│   └── Audio/
│       ├── DeviceManager.swift
│       ├── MicrophoneCapture.swift
│       ├── SystemAudioTap.swift
│       ├── AggregateDeviceManager.swift
│       ├── AudioSynchronizer.swift
│       ├── FormatConverter.swift
│       ├── AntiBleedPipeline.swift
│       └── VirtualMicWriter.swift
│
├── AECBridge/
│   ├── AECBridge.h
│   ├── AECBridge.mm
│   ├── AECProcessor.hpp
│   ├── AECProcessor.cpp
│   └── CMakeLists.txt / build integration
│
├── AntiBleedDriver/
│   ├── Driver/
│   ├── SharedRingBuffer/
│   ├── Info.plist
│   └── build scripts
│
├── DSP/
│   ├── RingBuffer.hpp
│   ├── Resampler.*
│   ├── SignalMetrics.*
│   ├── CouplingDetector.*
│   └── CrossFade.*
│
├── Tests/
│   ├── DSPTests/
│   ├── AECTests/
│   ├── SynchronizationTests/
│   ├── DriverTests/
│   ├── OfflineFixtures/
│   └── HardwareTestProtocol.md
│
├── Scripts/
│   ├── bootstrap-macos.sh
│   ├── build-webrtc.sh
│   ├── build-app.sh
│   ├── install-driver.sh
│   ├── uninstall-driver.sh
│   └── package.sh
│
└── Docs/
    ├── Architecture.md
    ├── DSP.md
    ├── Driver.md
    ├── Permissions.md
    ├── Testing.md
    └── Distribution.md
```

---

# 8. Signal format

Use one canonical internal format.

Recommended:

```text
Sample rate: 48,000 Hz
Sample type: Float32
Frame size: 10 ms
Samples/frame/channel: 480
AEC capture channels: 1 initially
AEC render channels: 1 initially
```

Why:

- WebRTC APM is built around real-time frame processing and accepts 10 ms frames.
- 48 kHz is common for communications and macOS audio.
- Float32 matches Core Audio well and avoids unnecessary integer quantization.

## 8.1 System audio

System output may be stereo.

For AEC MVP:

```text
L + R -> controlled mono downmix -> AEC far-end reference
```

Do not change the user's actual system playback.

Only the AEC reference is downmixed.

## 8.2 Microphone

Use mono for the AEC capture path.

If the hardware microphone exposes more channels:

- select the intended microphone channel,
- or produce a controlled mono mix,
- do not blindly sum channels.

## 8.3 Virtual microphone format

MVP:

```text
48 kHz
mono
Float32 internally
```

Production compatibility can add:

- 44.1 kHz,
- 48 kHz,
- optional stereo presentation with duplicated mono channels if a client requires it.

Do not add formats until actual compatibility tests justify them.

---

# 9. Capturing the actual system-output reference

## 9.1 Core Audio Tap

Use a `CATapDescription` bound to the selected physical output device.

The tap must represent the audio that is intended for the physical speaker/output device.

The application should create a private process tap and a private aggregate device.

Important configuration goals:

```text
tap visibility:       private
mute behavior:        do not mute normal output
target device:        selected physical output
own process:          excluded where appropriate
internal writer:      excluded
```

The user must continue hearing system audio normally.

## 9.2 Avoid self-reference / feedback contamination

Do not let the system-audio tap capture the application's internal `Anti-Bleed` writer stream.

Otherwise this can create an invalid reference or feedback path.

The tap should be tied to the actual physical output device and should exclude the Anti-Bleed process/internal virtual device where necessary.

Desired reference:

```text
audio actually intended for speaker/headphone output
```

Not:

```text
all audio on all Core Audio devices including Anti-Bleed's own virtual output
```

## 9.3 Permission

The app must include:

```text
NSAudioCaptureUsageDescription
```

The user must be clearly told that system-output capture is required only to identify audio that can leak from speakers into the microphone.

No system audio should be uploaded or recorded by default.

---

# 10. Capturing an unprocessed microphone

The input must be as close as reasonably possible to the raw physical microphone stream.

Do not intentionally enable:

- Voice Isolation,
- Voice Processing,
- Apple AEC,
- application noise suppression,
- AGC,
- AI denoising,
- third-party microphone enhancement.

## 10.1 Recommended capture path

Use AUHAL when the implementation reaches production quality because it provides explicit Core Audio device selection and low-level control.

`AVAudioEngine` can be used for the first spike if it is simpler.

If `AVAudioEngine` is used:

```text
inputNode.setVoiceProcessingEnabled(false)
```

must be called/verified.

## 10.2 Permission

The app must include:

```text
NSMicrophoneUsageDescription
```

If microphone permission is denied:

- do not crash,
- do not output stale samples,
- show an actionable error,
- virtual mic should output silence until a microphone becomes available.

---

# 11. Clocking and synchronization

This is one of the most important parts of the project.

AEC quality depends heavily on accurate and stable correspondence between:

```text
far-end frame sent toward the speaker
```

and:

```text
near-end frame that contains the resulting acoustic echo
```

## 11.1 Use Core Audio timestamps

Preserve timing metadata from capture.

Relevant `AudioTimeStamp` data includes:

- `mHostTime`,
- `mSampleTime`,
- `mRateScalar`.

Do not throw timing information away at the capture callbacks.

Each audio block entering the pipeline should conceptually have:

```text
AudioBlock {
    samples
    sampleRate
    channels
    hostTime
    sampleTime
    source
    sequenceNumber
}
```

## 11.2 Preferred synchronization architecture: private aggregate device

Investigate and prefer a private Core Audio aggregate device containing:

- the selected microphone as a subdevice,
- the system-output tap as a subtap.

Apple documents that aggregate devices synchronize clocks of their subdevices and subtaps during I/O.

This gives us a stronger timing foundation than two completely independent high-level capture pipelines.

Recommended initial clocking experiment:

```text
far-end/output-related tap = clock reference
microphone                = drift compensated
```

but this must be validated experimentally.

If the selected hardware or Core Audio configuration behaves better with the microphone as the clock source, support switching the master in the implementation.

Do not hard-code a clock-source assumption without measurement.

## 11.3 Ring buffers

Use bounded, preallocated ring buffers:

```text
RenderReferenceRing
RawMicRing
ProcessedMicRing
VirtualWriterRing
```

Each ring item should preserve enough timing metadata to align frames.

Requirements:

- no malloc/free in real-time callback,
- no unbounded queues,
- no blocking mutex on Core Audio real-time callbacks,
- defined overflow policy,
- defined underflow policy,
- telemetry counters for overruns/underruns.

## 11.4 Frame alignment

Use a layered approach:

### Layer 1 — Core Audio clock synchronization

Use aggregate-device clocking/drift compensation where available.

### Layer 2 — timestamp alignment

Align render and microphone blocks on `mHostTime` / sample time.

### Layer 3 — AEC3 delay estimator

Let AEC3 learn/refine the acoustic echo-path delay.

### Layer 4 — monitoring

Track:

- current AEC delay estimate,
- delay median,
- delay standard deviation,
- buffer skew,
- underruns,
- overruns,
- clock drift.

Do not solve synchronization by inserting one arbitrary fixed delay such as "80 ms".

A fixed offset may be useful as an initial estimate, never as the full solution.

---

# 12. WebRTC AEC3 integration

Use the official WebRTC Audio Processing Module.

The APM operates on:

```text
near-end / capture stream -> ProcessStream(...)
far-end  / render stream  -> ProcessReverseStream(...)
```

The render stream forms the echo reference.

## 12.1 Processing order

For each matched 10 ms window:

```text
1. receive/render reference frame
2. feed it to ProcessReverseStream
3. receive corresponding raw mic frame
4. feed it to ProcessStream
5. obtain AEC-cleaned mic frame
```

The implementation must maintain correct stream order even if Core Audio callback sizes differ from 480 frames.

Callbacks should write into FIFOs; a dedicated DSP worker should assemble exact 10 ms frames.

## 12.2 WebRTC configuration

Start conservatively:

```text
echo_canceller.enabled = true

noise_suppression.enabled = false
gain_controller.enabled = false
transient_suppression.enabled = false
```

Do not add additional processing to make demo recordings sound artificially impressive.

The test is whether speaker bleed is removed while near-end speech remains natural.

## 12.3 Keep AEC learning even when output is bypassed

Important distinction:

```text
AEC processing state
```

and:

```text
which signal is exposed through Anti-Bleed_mic
```

should be separate.

During `BYPASS` or `LEARNING` state:

- the AEC engine may continue receiving render + mic frames and adapting,
- the virtual microphone can still output raw mic.

This lets AEC warm up without exposing unstable cancellation artifacts to Discord.

---

# 13. Safety system: prevent "inverse desktop audio"

The user's critical safety requirement is:

> If the system audio is not actually acoustically entering the microphone, cancellation must not create an artificial inverted copy of desktop audio in the virtual microphone.

A correctly functioning adaptive AEC should converge toward a near-zero echo path when there is no acoustic coupling; it should not behave like naïve subtraction.

Nevertheless, Anti-Bleed must implement a separate safety/bypass layer.

## 13.1 Never generate a direct inverted reference

Hard invariant:

```text
virtual_output MUST NEVER be rawMic - rawRender
```

The selectable outputs are only:

```text
raw mic
AEC-processed mic
a controlled crossfade between those two
silence on fatal input failure
```

Never output an independently inverted render signal.

## 13.2 State machine

Use explicit states:

```text
STOPPED
BYPASS
PROBING
LEARNING
ACTIVE
DEGRADED
ERROR
```

### STOPPED

Pipeline not running.

### BYPASS

Output:

```text
Anti-Bleed_mic = raw microphone
```

AEC can remain internally warm if resources permit.

Typical reasons:

- render reference is silent,
- headphones are in use and no acoustic coupling is detected,
- AEC has no reliable echo path,
- AEC is divergent,
- system-audio tap temporarily failed.

### PROBING

Render is active.

Measure whether a stable speaker-to-microphone path exists.

Output remains raw mic.

### LEARNING

Acoustic coupling appears real.

AEC adapts and establishes a stable delay/filter.

Output remains raw mic or gradually begins a very conservative blend.

### ACTIVE

AEC has enough confidence.

Output is AEC-cleaned microphone.

### DEGRADED

AEC confidence fell.

Crossfade back to raw mic.

Reset/relearn if necessary.

### ERROR

Critical capture/write failure.

Prefer silence over stale/repeated samples.

## 13.3 Render activity detector

If the render reference is effectively silent for a configurable hangover period:

```text
output = raw mic
```

There is nothing to cancel.

Measure:

- render RMS,
- render peak,
- activity duration.

Do not switch states on one silent 10 ms frame.

Use hysteresis.

## 13.4 Acoustic coupling detector

Render being active is **not sufficient**.

Example:

```text
YouTube playing through headphones
```

The render reference is active but there may be zero meaningful speaker bleed into the MacBook microphone.

Determine whether a stable acoustic path exists using multiple signals.

Candidate metrics:

1. normalized correlation / coherence between delayed render and raw mic,
2. stability of the detected correlation delay,
3. AEC3 `delay_ms`,
4. AEC3 `delay_median_ms`,
5. AEC3 `delay_standard_deviation_ms`,
6. AEC3 `echo_return_loss`,
7. AEC3 `echo_return_loss_enhancement`,
8. AEC3 `divergent_filter_fraction`,
9. AEC3 residual echo likelihood metrics.

No single metric should be trusted by itself.

## 13.5 Stable correlation requirement

A real echo path should usually produce:

- a repeatable delay region,
- meaningful correlation between render and microphone,
- persistence over multiple windows.

Coincidental speech similarity must not activate AEC immediately.

Use a window long enough to reject one-frame coincidences.

Potential methods:

- normalized cross-correlation,
- frequency-domain coherence,
- GCC-PHAT for coarse delay estimation.

AEC3 already contains delay estimation, so this external estimator should be used as a **safety/confidence signal**, not as a replacement for AEC3.

## 13.6 Headphone behavior

When headphones are connected:

```text
system audio reference = active
physical speaker bleed = approximately absent
```

Expected behavior:

```text
coupling confidence -> low
state -> BYPASS
Anti-Bleed_mic -> raw mic
```

Do not rely solely on the output device transport type.

A USB/Bluetooth device might be:

- headphones,
- a speaker,
- a dock,
- a monitor,
- another acoustic source.

Therefore:

```text
device route heuristic = supporting evidence
actual measured acoustic coupling = primary evidence
```

## 13.7 Speaker mute / volume zero

System audio may continue to exist digitally even when the physical output is muted.

Therefore:

```text
render active != acoustic echo active
```

The coupling detector must still keep the pipeline in BYPASS if no speaker path is observed.

## 13.8 Crossfade instead of hard switching

Switching directly between raw and processed buffers can create clicks or discontinuities.

Use a short controlled crossfade:

```text
raw -> processed
processed -> raw
```

Suggested starting range:

```text
50–150 ms
```

Tune experimentally.

## 13.9 Divergence fail-safe

If AEC reports a divergent filter or the processed signal becomes suspicious:

```text
ACTIVE -> DEGRADED -> BYPASS
```

The failure mode must be:

```text
speaker bleed returns temporarily
```

not:

```text
user voice is destroyed or an inverted desktop signal is transmitted
```

That priority is important.

---

# 14. Starting tuning values

These are **initial experimental values**, not product guarantees.

They must be tuned from real recordings.

Potential starting parameters:

```text
render activity window:       200–500 ms
coupling analysis window:     300–1000 ms
state-enter hysteresis:       ~500 ms
state-exit hysteresis:        ~500–1500 ms
crossfade:                    50–150 ms
startup AEC learning period:  1–3 s
```

Do not lock correlation, ERLE, or RMS thresholds before collecting hardware data.

Add all thresholds to a diagnostics configuration file during development.

The release UI should not expose dozens of DSP tuning knobs.

---

# 15. Virtual microphone design

The final user experience must not require BlackHole.

The system should expose:

```text
Input devices:
    MacBook Microphone
    Anti-Bleed_mic
```

The application internally needs a way to feed cleaned PCM into `Anti-Bleed_mic`.

## 15.1 Use an Audio Server Plug-in

Apple's guidance is to build a virtual audio device using an Audio Server Driver Plug-in.

Do **not** choose AudioDriverKit merely because it sounds newer.

Apple explicitly documents Audio Server Driver Plug-ins as the preferred mechanism for virtual devices, while AudioDriverKit is intended for physical audio-device drivers.

## 15.2 Two internal virtual devices

Recommended production architecture:

### Visible device

```text
Name: Anti-Bleed_mic
Hidden: false
Input: true
Output: false
```

This is the device the user sees and selects in Discord.

### Hidden writer device

```text
Name/UID: Anti-Bleed_internal_writer
Hidden: true
Input: false
Output: true
```

The Anti-Bleed application discovers this device by UID and writes the processed microphone signal to it.

Both virtual devices share the same driver-side ring buffer.

Conceptually:

```text
Anti-Bleed app
      |
      | Core Audio output writes
      v
Anti-Bleed_internal_writer   [hidden]
      |
      | shared driver ring buffer
      v
Anti-Bleed_mic               [visible input]
      |
      v
Discord
```

This avoids:

- an external IPC protocol between app and driver,
- showing an unnecessary virtual output device to normal users,
- forcing the user to configure an aggregate/multi-output device.

## 15.3 Driver underflow behavior

If the app stops writing:

```text
Anti-Bleed_mic -> silence
```

Never:

- replay the last buffer,
- loop old audio,
- expose uninitialized memory.

## 15.4 Driver overrun behavior

Drop the oldest stale data or follow the chosen real-time ring-buffer policy.

The newest real-time microphone data is more valuable than preserving old latency.

Track counters for diagnostics.

## 15.5 Driver installation

Audio Server Plug-in bundle location:

```text
/Library/Audio/Plug-Ins/HAL
```

Development installer/uninstaller scripts should:

- copy/remove the driver,
- restart Core Audio where appropriate,
- verify that the device appears,
- verify hidden writer UID lookup,
- fail cleanly.

Production should ship a proper signed installer package.

---

# 16. BlackHole MVP path

Before writing the custom driver, validate DSP with:

```text
AEC output -> BlackHole -> Discord
```

This lets the project prove the difficult signal-processing portion before debugging a custom driver simultaneously.

MVP flow:

```text
Core Audio Tap
      +
Raw microphone
      |
      v
AEC3
      |
      v
BlackHole 2ch
      |
      v
Discord input
```

Once speaker bleed cancellation works reliably, replace BlackHole with the custom `Anti-Bleed_mic` driver.

## 16.1 Licensing warning

BlackHole is GPL-3.0 and its project documentation states that non-GPL projects require a separate license.

Therefore:

- using BlackHole as an installed development dependency is fine for prototyping,
- do not copy BlackHole source into a proprietary project without resolving licensing,
- do not mechanically fork/rename BlackHole for a closed-source commercial release,
- implement the production Audio Server Plug-in from Apple's sample/API documentation or use an appropriately licensed implementation.

---

# 17. Output-device monitoring

Monitor Core Audio device changes.

Important events:

- default physical output changed,
- output device removed,
- headphones plugged/unplugged,
- Bluetooth route changed,
- output sample rate changed,
- output device became unavailable,
- selected microphone changed/disconnected,
- aggregate device lost a subdevice.

On an output-route change:

```text
1. immediately crossfade to raw mic
2. tear down old tap
3. create tap for new physical output
4. reset synchronization state
5. reset/reinitialize AEC echo path
6. enter PROBING/LEARNING
7. activate AEC only after confidence returns
```

Never continue applying the old room/speaker filter to a new output device.

---

# 18. Input-device monitoring

On microphone change:

```text
1. stop virtual processed output safely
2. switch to new raw microphone
3. rebuild aggregate/sync configuration
4. reset AEC
5. relearn acoustic path
```

The physical microphone's acoustic transfer path changes when:

- microphone changes,
- Mac lid position changes significantly,
- external mic is connected,
- microphone gain changes,
- microphone moves.

AEC3 should adapt to gradual path changes, but explicit device changes should trigger a reset.

---

# 19. Real-time threading rules

Audio callbacks are real-time code.

Hard rules:

- no network access,
- no logging to disk,
- no heap allocation,
- no SwiftUI interaction,
- no blocking locks,
- no waiting on semaphores with unbounded time,
- no file I/O,
- no JSON,
- no process spawning.

Callbacks should perform only minimal work:

```text
copy/convert fixed buffer
attach timestamp metadata
push into lock-free/bounded queue
return
```

AEC processing should run on a dedicated high-priority DSP thread, not inside UI code.

Driver callbacks must follow the same discipline.

---

# 20. DSP pipeline

Detailed per-frame path:

```text
SYSTEM TAP CALLBACK
    |
    +--> capture Float32 block
    +--> preserve timestamp
    +--> push RenderReferenceRing

MIC CALLBACK
    |
    +--> capture unprocessed Float32 block
    +--> preserve timestamp
    +--> push RawMicRing

DSP WORKER
    |
    +--> pull timestamp-aligned blocks
    +--> resample if needed
    +--> construct exact 10 ms / 480-sample frames
    +--> update render activity metrics
    +--> update coupling metrics
    +--> AEC.ProcessReverseStream(render)
    +--> AEC.ProcessStream(rawMic)
    +--> obtain processedMic
    +--> update AEC statistics
    +--> state machine decides raw/processed/crossfade
    +--> limiter/sanity protection only if necessary
    +--> push final mic frame

VIRTUAL WRITER
    |
    +--> write final frame to hidden virtual output

DRIVER
    |
    +--> expose the shared stream on Anti-Bleed_mic
```

---

# 21. Resampling strategy

Avoid unnecessary resampling.

Ideal:

```text
physical output reference: 48 kHz
physical mic:              48 kHz
AEC internal:              48 kHz
virtual mic:               48 kHz
```

If hardware provides a different rate:

- use a high-quality streaming resampler,
- preserve continuous phase/state,
- account for resampler delay,
- do not resample each block independently,
- include resampler latency in synchronization metrics.

Drift correction may require very small continuously changing rate adjustment between independently clocked devices.

Where Core Audio aggregate-device drift compensation solves this reliably, prefer it over custom clock correction.

---

# 22. Double-talk handling

Critical scenario:

```text
friend speaks from speaker
AND
user speaks at the same time
```

The system must remove the far-end echo while preserving the near-end speaker.

This is called double-talk.

Do not implement simplistic logic such as:

```text
if mic loud -> disable AEC
```

That would fail precisely when the user talks over someone else.

AEC3 is designed to handle double-talk.

The safety gate should evaluate echo-path confidence over time and must not disable cancellation simply because near-end speech is present.

---

# 23. Nonlinear loudspeaker behavior

At high speaker volumes the physical speaker may introduce nonlinear distortion.

The microphone echo can then contain components not perfectly represented by a linear convolution of the digital reference.

Expect AEC performance to decrease at:

- maximum speaker volume,
- clipping,
- strong bass distortion,
- unusual external speakers.

Testing must include multiple output volume levels.

Do not claim 100% cancellation under every acoustic condition.

The goal is robust attenuation without damaging near-end speech.

---

# 24. Diagnostics

Development builds need extensive diagnostics.

UI/debug page should expose:

```text
Selected microphone
Selected physical output
Tap status
Virtual driver status

Mic sample rate
Render sample rate
Virtual sample rate

Raw mic RMS
Render RMS
Processed mic RMS

AEC state
Coupling confidence
AEC delay estimate
Delay median
Delay stddev
ERL
ERLE
Residual echo likelihood
Divergent filter fraction

Render queue depth
Mic queue depth
Output queue depth

Dropped render frames
Dropped mic frames
Virtual writer underruns
Virtual writer overruns

Current latency estimate
```

Release builds may hide advanced statistics behind an "Advanced Diagnostics" panel.

---

# 25. Minimal user interface

Prefer a menu-bar application.

Example:

```text
Anti-Bleed

Status: Active

Microphone
[ MacBook Microphone                 v ]

Output reference
[ MacBook Speakers                   v ]

Virtual microphone
Anti-Bleed_mic  Ready

Echo cancellation
[ ON ]

Raw Mic       [ meter ]
Speaker Ref   [ meter ]
Clean Mic     [ meter ]

AEC: Active
Estimated echo delay: 72 ms

[ Test Microphone ]
[ Advanced Diagnostics ]
[ Quit ]
```

State labels should be understandable:

```text
Bypass — no speaker echo detected
Learning speaker path
Active
Reconnecting audio device
Permission required
Driver unavailable
```

Do not label ordinary AEC bypass as an error.

---

# 26. Permissions UX

Two independent permissions may be required:

## Microphone

`NSMicrophoneUsageDescription`

Suggested purpose:

> Anti-Bleed needs microphone access to create the cleaned virtual microphone.

## System audio capture

`NSAudioCaptureUsageDescription`

Suggested purpose:

> Anti-Bleed reads the audio sent to your output device locally so it can remove speaker bleed from your microphone.

Privacy guarantees:

- processing happens locally,
- no account required,
- no cloud service,
- no upload,
- no recording by default,
- debug dumps require explicit developer/test action.

---

# 27. Failure behavior

The project must be fail-safe.

## 27.1 System tap failure

Output:

```text
raw microphone
```

Show:

```text
AEC unavailable — system audio reference lost
```

Do not fabricate cancellation.

## 27.2 AEC failure/divergence

Output:

```text
raw microphone
```

Reset AEC asynchronously.

## 27.3 No system audio

Output:

```text
raw microphone
```

No need to spend unnecessary DSP effort beyond keeping minimal state warm.

## 27.4 Headphones / no acoustic coupling

Output:

```text
raw microphone
```

Even if digital render audio is active.

## 27.5 Microphone failure

Output:

```text
silence
```

Do not repeat stale data.

## 27.6 Virtual writer failure

Attempt recovery.

If driver cannot receive current data:

```text
virtual input -> silence
```

## 27.7 Application crash

Driver should eventually underflow to silence.

It must never keep playing old audio.

---

# 28. Offline DSP test harness

Do not begin with Discord as the only test.

Create deterministic offline tests.

Generate:

```text
render(t)
wantedVoice(t)
noise(t)
```

Generate synthetic microphone:

```text
mic(t) = wantedVoice(t)
       + noise(t)
       + convolution(render(t), syntheticRoomIR)
```

Feed:

```text
render -> AEC reverse stream
mic    -> AEC capture stream
```

Measure cancellation.

## 28.1 Required synthetic cases

### Case A — fixed echo

Known FIR impulse response.

Expected:

- strong reduction of render component,
- wanted voice preserved.

### Case B — delay sweep

Test acoustic/system delay across a range such as:

```text
0–250 ms
```

### Case C — amplitude sweep

Change speaker-to-mic gain.

### Case D — room reflections

Use multi-tap impulse response.

### Case E — double-talk

Render + wanted speech simultaneously.

### Case F — render only

No near-end speech.

AEC should strongly attenuate render leakage.

### Case G — wanted speech only

Render silent.

Safety path should return raw signal without meaningful modification.

### Case H — headphones/no coupling

Render active, but:

```text
mic = wantedVoice + noise
```

Expected:

```text
virtualOutput ≈ rawMic
```

No inverse render content is allowed.

### Case I — clock drift

Simulate sample-rate drift between render/capture clocks.

### Case J — route change

Change synthetic echo impulse response abruptly.

System should temporarily bypass, relearn, then reactivate.

---

# 29. Hardware test protocol

A real Mac test is mandatory.

Record three synchronized diagnostic tracks during development:

```text
1. raw microphone
2. system render reference
3. Anti-Bleed processed output
```

These tracks should only be available in an explicit development/debug recording mode.

## 29.1 Test matrix

### Speaker tests

Run at approximately:

```text
25% volume
50% volume
75% volume
high but non-clipping volume
```

Content:

- male speech,
- female speech,
- music,
- game audio,
- Discord call speech,
- abrupt sound effects.

### Near-end tests

- user silent,
- user speaks continuously,
- user speaks intermittently,
- user speaks over far-end speaker,
- keyboard while far-end audio plays,
- room noise while far-end audio plays.

### Physical changes

- laptop lid angle change,
- move laptop on desk,
- move user position,
- switch room if available.

### Output-route changes

- MacBook speakers,
- wired headphones,
- AirPods/Bluetooth headphones,
- external monitor speakers if available,
- external USB audio device,
- mute/unmute,
- volume step,
- unplug/replug.

### Microphone changes

- MacBook microphone,
- external USB microphone if available.

---

# 30. Acceptance metrics

These are product targets to validate, not assumptions that are already achieved.

## Core correctness

### Render silent

```text
Anti-Bleed_mic ≈ raw microphone
```

No meaningful coloration should be introduced.

### Headphones/no coupling

With system audio active but no acoustic coupling:

```text
Anti-Bleed_mic ≈ raw microphone
```

No audible inverted desktop signal.

### Speaker bleed

When speaker audio is clearly captured by the microphone:

Target initial attenuation:

```text
>= 20 dB echo reduction in representative conditions
```

Stretch target:

```text
>= 30 dB where the acoustic path permits it
```

Use objective measurements plus listening tests.

### Double-talk

User speech must remain intelligible while far-end speaker audio is being cancelled.

## Stability

No:

- repeated audio,
- feedback loop,
- growing latency,
- periodic clicking,
- buffer starvation under normal load,
- random switch between raw/AEC every few frames.

## Latency target

Additional microphone latency target:

```text
< 50 ms
```

Stretch:

```text
< 30 ms
```

Measure, do not estimate from code.

## CPU target

Initial Apple Silicon target:

```text
< 5% average CPU for the full pipeline during normal use
```

Treat this as an optimization target, not a release blocker until measured.

---

# 31. Automated signal-quality checks

Build scripts/tests that calculate:

- RMS,
- peak,
- correlation,
- echo attenuation,
- ERLE where meaningful,
- wanted-speech distortion,
- output vs raw difference in bypass cases,
- latency alignment,
- clipping count.

A critical regression test:

```text
render active
no render component in microphone
```

must verify that the final output does not suddenly acquire a render-correlated component.

This directly protects the "no inverse desktop audio" requirement.

---

# 32. Phase-by-phase implementation plan

## Phase 0 — Repository + build skeleton

Deliverables:

- macOS Swift app builds,
- C++ bridge builds,
- unit test target runs,
- macOS CI runs,
- no DSP yet.

Acceptance:

```text
clean clone -> documented build succeeds on Mac
```

---

## Phase 1 — Raw microphone capture

Implement:

- device enumeration,
- selected microphone capture,
- voice processing explicitly disabled,
- 48 kHz conversion if necessary,
- 10 ms framing,
- RMS meter,
- permission handling.

Acceptance:

- raw mic can be monitored/recorded in a dev test,
- no intentional NS/AGC/AEC,
- device switching works.

---

## Phase 2 — Core Audio system tap

Implement:

- physical output enumeration,
- process/system tap,
- permission handling,
- render capture,
- timestamps,
- RMS meter,
- own-process exclusion.

Acceptance:

- YouTube/Discord system output is captured,
- user still hears normal speaker output,
- Anti-Bleed's internal output is not recursively captured.

---

## Phase 3 — Unified timing / aggregate device

Implement:

- private aggregate device,
- selected mic subdevice,
- system tap subtap,
- clock source selection,
- drift correction,
- timestamped queues,
- 10 ms frame assembler.

Acceptance:

- render/mic timing stays bounded for a long-running session,
- queue depth does not steadily grow,
- no periodic frame slip.

Run at least a 30–60 minute stability test.

---

## Phase 4 — Offline WebRTC AEC3

Before connecting live hardware, integrate AEC3 into offline tests.

Implement:

- pinned WebRTC revision,
- C++ AEC wrapper,
- render/capture APIs,
- stats extraction,
- synthetic echo tests.

Acceptance:

- synthetic fixed-delay echo cancellation works,
- double-talk test passes,
- no-coupling test does not inject render audio.

---

## Phase 5 — Live AEC

Connect:

```text
system tap -> AEC reverse
raw mic    -> AEC capture
```

Output processed PCM to a debug sink/file or headphones only for explicit testing.

Acceptance:

- real Mac speaker bleed is audibly reduced,
- near-end voice remains intelligible.

Do not build custom driver yet if cancellation itself is not proven.

---

## Phase 6 — BlackHole integration MVP

Temporarily output processed mic to BlackHole.

Discord:

```text
Input Device = BlackHole
```

Acceptance:

- real Discord call receives the AEC-processed mic,
- friend/YouTube speaker bleed is substantially reduced,
- user speech is preserved,
- headphones case does not create inverted output.

This phase proves the end-to-end product behavior before custom-driver work.

---

## Phase 7 — Safety state machine

Implement:

- render activity detection,
- coupling detector,
- AEC confidence metrics,
- BYPASS/PROBING/LEARNING/ACTIVE/DEGRADED states,
- crossfade,
- route-change reset,
- divergence fail-safe.

Acceptance:

1. render silent -> raw passthrough,
2. headphones + active render -> raw passthrough,
3. speaker coupling -> AEC activates,
4. disconnect speaker route -> safely returns to bypass,
5. AEC divergence -> safely returns to bypass.

---

## Phase 8 — Custom `Anti-Bleed_mic` virtual driver

Implement Audio Server Plug-in.

Devices:

```text
Anti-Bleed_mic             visible, input only
Anti-Bleed_internal_writer hidden, output only
```

Implement shared driver ring buffer.

Application writes clean signal to hidden output.

Acceptance:

- `Anti-Bleed_mic` appears as a standard input device,
- hidden writer is not shown in ordinary device selectors,
- Discord can select `Anti-Bleed_mic`,
- app can locate the hidden writer by UID,
- writer->input latency is stable,
- underflow outputs silence.

---

## Phase 9 — Remove BlackHole runtime dependency

The application must function on a clean Mac without BlackHole.

Acceptance:

```text
install Anti-Bleed
grant permissions
select Anti-Bleed_mic in Discord
works
```

No Audio MIDI Setup manual routing required.

---

## Phase 10 — Product UI and recovery

Implement:

- menu bar UI,
- input/output selectors,
- status,
- meters,
- permission actions,
- driver health,
- automatic recovery,
- advanced diagnostics.

Acceptance:

A normal user does not need Terminal or Audio MIDI Setup after installation.

---

## Phase 11 — Packaging and distribution

Development:

- local build/install scripts.

Public distribution:

- Developer ID signing,
- Hardened Runtime,
- sign app,
- sign plug-in,
- sign installer,
- notarize,
- staple ticket,
- verify Gatekeeper behavior.

Package as a signed `.pkg` or a `.dmg` containing an installer flow appropriate for the audio driver.

---

# 33. Build strategy for WebRTC

Prefer the official WebRTC source/build process over an abandoned binary package.

Pin an exact WebRTC commit.

Do not build against floating `main` in production.

Repository should record:

```text
WEBRTC_REVISION=<commit SHA>
```

Build automation should:

1. install/configure `depot_tools`,
2. fetch WebRTC,
3. sync the pinned revision/dependencies,
4. generate GN build files,
5. build only the required APM/audio-processing targets where practical,
6. produce deterministic static libraries for the app,
7. archive licenses/NOTICE files with the release.

Do not check a multi-gigabyte WebRTC checkout into this repository.

Cache build artifacts in CI where licensing/build policy permits.

---

# 34. Versioning and reproducibility

Pin:

- Xcode major version in CI,
- macOS deployment target,
- WebRTC commit,
- compiler settings,
- virtual-driver ABI/version,
- DSP configuration schema.

Store build metadata in the app's diagnostics:

```text
Anti-Bleed version
Git commit
WebRTC revision
Driver version
macOS version
CPU architecture
```

This is important when debugging audio behavior.

---

# 35. CI/CD

## Pull request CI

On macOS runner:

- Swift build,
- C++ build,
- unit tests,
- offline DSP tests,
- driver compile,
- static analysis where configured.

On Windows/Linux runner if useful:

- platform-independent C++ DSP tests.

## Release CI

On macOS:

- Release build,
- code signing,
- package assembly,
- notarization,
- staple,
- signature verification,
- artifact checksum.

Secrets:

- signing certificates,
- notarization credentials,

must be stored only in secure CI secret storage.

Never commit certificates or credentials.

## Hardware validation

Do not mark a release "audio validated" based only on CI.

A physical Mac hardware test remains a required release gate until automated hardware-in-the-loop infrastructure exists.

---

# 36. Installer strategy

The installer must install both:

```text
Anti-Bleed.app
Anti-Bleed.driver
```

The driver installation may require administrator privileges.

Installer should:

1. verify supported macOS,
2. install application,
3. install driver,
4. restart/reload Core Audio as required,
5. verify `Anti-Bleed_mic`,
6. launch app,
7. request microphone/system-audio permissions through the app.

Uninstaller should remove:

- app,
- driver,
- optional preferences,
- optional logs if the user chooses.

It must not remove unrelated audio devices.

---

# 37. Distribution/security requirements

For direct distribution outside the Mac App Store:

- Apple Developer Program membership is required for normal Developer ID distribution,
- sign application,
- sign plug-in/driver bundle,
- sign installer,
- use Hardened Runtime where required,
- notarize,
- staple notarization ticket,
- verify with Gatekeeper tools.

The project should initially target direct distribution rather than assume Mac App Store packaging, because a HAL Audio Server Plug-in installed system-wide has installer/distribution constraints that do not fit a simple sandboxed-app model.

---

# 38. Privacy and security

Core principle:

```text
All audio processing stays on the Mac.
```

No:

- cloud API,
- speech-to-text,
- analytics containing audio,
- hidden recording,
- remote DSP service.

Telemetry, if ever introduced, must contain only opt-in non-audio technical metrics.

Debug WAV dumps:

- disabled by default,
- developer-only or explicit opt-in,
- show a visible indicator,
- have a defined deletion path.

---

# 39. Logging

Normal logs may include:

- device IDs/names,
- state transitions,
- permission state,
- AEC metrics,
- queue statistics,
- error codes.

Do not log:

- raw PCM,
- transcripts,
- audio contents.

Use rate-limited logging.

Never log every 10 ms frame.

---

# 40. Important edge cases

Must explicitly test:

1. system volume = 0,
2. system muted,
3. render audio paused,
4. wired headphones connected,
5. Bluetooth headphones connected,
6. external speakers connected,
7. HDMI/monitor audio,
8. output device changes during call,
9. microphone changes during call,
10. microphone unplugged,
11. output unplugged,
12. macOS sleep/wake,
13. app restart while Discord is open,
14. Core Audio restart,
15. driver installed but app not running,
16. app running but permissions denied,
17. Discord opens virtual mic before Anti-Bleed starts,
18. 44.1 kHz source,
19. 48 kHz source,
20. CPU load spike,
21. render queue underrun,
22. mic queue underrun,
23. sudden output volume change,
24. speaker movement / lid angle change,
25. near-end and far-end speech simultaneously,
26. loud far-end music,
27. very quiet far-end speech,
28. output clipping,
29. microphone clipping.

---

# 41. What NOT to do

Do not:

- solve the problem with ordinary RNNoise only,
- call generic AI denoising "echo cancellation",
- direct-subtract system audio,
- route system audio into the virtual microphone,
- expose raw system output in `Anti-Bleed_mic`,
- enable AGC/NS without an explicit reason,
- rely on a fixed 50/80/100 ms delay,
- assume headphones based only on Bluetooth/USB transport,
- process UI work on audio callbacks,
- allocate memory in real-time callbacks,
- keep stale audio after app failure,
- silently record audio,
- make BlackHole a hidden permanent dependency,
- copy GPL BlackHole code into a closed-source release without resolving licensing,
- choose AudioDriverKit for a purely virtual mic when Audio Server Plug-in is the appropriate architecture.

---

# 42. Suggested engineering milestones

## Milestone A — Can capture both sources

```text
[ ] Raw microphone captured
[ ] System render captured
[ ] Both timestamped
[ ] 48 kHz framing works
```

## Milestone B — AEC works offline

```text
[ ] WebRTC AEC3 built
[ ] Synthetic echo removed
[ ] Double-talk works
[ ] No-coupling regression passes
```

## Milestone C — AEC works live

```text
[ ] Mac speaker audio suppressed
[ ] User speech preserved
[ ] Delay remains stable
[ ] Long-running test stable
```

## Milestone D — Safe auto-bypass

```text
[ ] Render silence bypass
[ ] Headphone/no-coupling bypass
[ ] AEC divergence bypass
[ ] Crossfades artifact-free
```

## Milestone E — Discord MVP

```text
[ ] Processed signal routed through BlackHole
[ ] Discord call verified
```

## Milestone F — Native Anti-Bleed virtual mic

```text
[ ] Driver installed
[ ] Anti-Bleed_mic visible
[ ] Internal writer hidden
[ ] Discord can select device
[ ] BlackHole removed
```

## Milestone G — Release

```text
[ ] Installer
[ ] Uninstaller
[ ] Signing
[ ] Notarization
[ ] Hardware matrix
[ ] Release diagnostics
```

---

# 43. Definition of Done

The project is complete for v1 when all of the following are true:

1. A clean supported Mac can install Anti-Bleed without installing BlackHole.
2. `Anti-Bleed_mic` appears as a normal microphone input.
3. User selects a real physical microphone inside Anti-Bleed.
4. User selects/uses a physical output device.
5. Anti-Bleed captures the physical-output render reference using Core Audio.
6. Anti-Bleed captures an unprocessed physical microphone stream.
7. Render and microphone streams remain synchronized over long calls.
8. WebRTC AEC3 removes speaker-originated microphone bleed.
9. Double-talk preserves the user's speech.
10. System-audio silence automatically results in raw-mic bypass.
11. Active system audio with no acoustic coupling (headphones/muted speaker) results in raw-mic bypass.
12. No inverse desktop signal is injected into the virtual microphone.
13. AEC divergence causes safe fallback to raw microphone.
14. Route changes automatically trigger relearning.
15. Discord can use `Anti-Bleed_mic` without manual Audio MIDI Setup routing.
16. Application crash does not replay stale microphone content.
17. Processing remains entirely local.
18. Build is reproducible.
19. Public build is signed/notarized.
20. Hardware tests demonstrate meaningful speaker-bleed attenuation with acceptable speech quality and latency.

---

# 44. Recommended implementation order

Do not start by writing the driver.

The most efficient sequence is:

```text
1. Raw mic capture
2. System output tap
3. Timing/synchronization
4. Offline AEC3
5. Live AEC3
6. Safety/coupling detection
7. BlackHole Discord MVP
8. Custom Anti-Bleed driver
9. Product UI
10. Packaging/signing/notarization
```

Reason:

The highest technical risk is not making a device appear in Discord.

The highest technical risk is producing **stable, correctly synchronized AEC that removes actual acoustic bleed without damaging the wanted microphone signal**.

Prove that first.

---

# 45. Architecture decision summary

Final intended architecture:

```text
                    SELECTED PHYSICAL OUTPUT
                              |
                 +------------+------------+
                 |                         |
                 v                         v
            loudspeaker               Core Audio Tap
                 |                         |
                 | acoustic echo           | exact digital reference
                 v                         |
          physical microphone              |
                 |                         |
                 +-----------+-------------+
                             |
                      synchronized frames
                             |
                             v
                       WebRTC AEC3
                             |
                             v
                      safety state machine
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
              Anti-Bleed_internal_writer
                       (hidden output)
                             |
                             v
                   driver shared buffer
                             |
                             v
                     Anti-Bleed_mic
                      (visible input)
                             |
                             v
                          Discord
```

This architecture directly satisfies the project requirement:

> Capture the exact system-output reference, capture the unprocessed microphone, synchronize them, estimate and cancel the physical speaker-to-microphone echo path, automatically bypass cancellation when no real acoustic echo path exists, and publish only the safe final microphone stream through a standard virtual input called `Anti-Bleed_mic`.

---

# 46. Primary technical references

The implementation agent should read the primary sources below before writing the corresponding subsystem.

## Apple — Core Audio system taps

Capturing system audio with Core Audio taps:

https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

`CATapDescription`:

https://developer.apple.com/documentation/coreaudio/catapdescription

## Apple — Aggregate audio devices and synchronization

`AudioHardwareAggregateDevice`:

https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice

Core Audio framework:

https://developer.apple.com/documentation/coreaudio

## Apple — Core Audio timestamps

`AudioTimeStamp`:

https://developer.apple.com/documentation/coreaudiotypes/audiotimestamp

`AudioDeviceIOProc`:

https://developer.apple.com/documentation/coreaudio/audiodeviceioproc

## Apple — Raw microphone / voice processing state

`AVAudioIONode`:

https://developer.apple.com/documentation/avfaudio/avaudioionode

`setVoiceProcessingEnabled`:

https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)

AUHAL technical note:

https://developer.apple.com/library/archive/technotes/tn2091/_index.html

## Apple — Permissions

`NSMicrophoneUsageDescription`:

https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription

`NSAudioCaptureUsageDescription`:

https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription

## Apple — Virtual audio device

Creating an Audio Server Driver Plug-in:

https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in

`kAudioDevicePropertyIsHidden`:

https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyishidden

AudioDriverKit note/reference:

https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver

## WebRTC — Audio Processing Module

APM overview:

https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/g3doc/audio_processing_module.md

Current audio-processing API:

https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h

AEC3 configuration:

https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/echo_canceller3_config.h

AEC statistics:

https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing_statistics.h

WebRTC native build:

https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/development/

## BlackHole — reference/MVP only

BlackHole project:

https://github.com/ExistentialAudio/BlackHole

Its developer documentation demonstrates:

- virtual loopback devices,
- hidden devices,
- separate visible input + hidden writer patterns,
- zero-additional-driver-latency routing concepts.

Respect its GPL-3.0 licensing requirements.

## Apple — public distribution

Developer ID:

https://developer.apple.com/support/developer-id/

Notarization:

https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

macOS distribution:

https://developer.apple.com/macos/distribution/

---

# 47. Agent execution rules

When an autonomous coding agent implements this plan:

1. Work phase-by-phase.
2. Do not skip directly to UI.
3. Read Apple's current API documentation before implementing Core Audio behavior.
4. Read the pinned WebRTC API at the exact revision being compiled.
5. Do not guess WebRTC function signatures from old blog posts.
6. Keep platform-independent DSP separately testable.
7. Add a regression test for every audio corruption bug.
8. Never weaken the no-coupling/no-inverse test to make CI pass.
9. Treat real-time callback constraints as correctness requirements.
10. Do not claim a Mac build passed unless it actually ran on macOS.
11. Do not claim speaker cancellation works based only on synthetic tests.
12. Preserve raw/reference/processed debug paths for engineering builds.
13. Keep NS/AGC disabled unless the specification is intentionally changed.
14. Preserve safe raw-microphone fallback on any AEC uncertainty.
15. Do not introduce cloud dependencies.
16. Do not copy GPL implementation code into a non-GPL product without explicit licensing approval.

---

# 48. First concrete implementation task

The first engineering PR should contain only:

```text
- macOS Swift app skeleton
- Core Audio device enumeration
- raw microphone capture
- microphone permission handling
- explicit voice-processing-disabled verification
- timestamped 48 kHz Float32 ring buffer
- RMS meter
- unit tests for ring buffer/frame assembler
- macOS CI build
```

The second PR should add only:

```text
- Core Audio physical-output enumeration
- Core Audio process tap
- system-audio permission
- timestamped render ring buffer
- render meter
- own-process/internal-device exclusion
```

Only after both streams are reliable should the project introduce AEC.

That ordering minimizes simultaneous unknowns and makes failures diagnosable.
