# Phase 1: Raw Microphone Capture

> PLAN.md chapters: 8, 10, 19, 20, 21, 24, 26, 40, 48.
> Prerequisite: Phase 0 DONE - repo builds on Mac, CI green, RingBuffer tested.
> Status: NOT STARTED

## Objective

Capture an unprocessed microphone stream at the canonical format (48 kHz / Float32 / 10 ms mono frames) with device enumeration, permission handling, and diagnostics. No AEC, no system-tap, no virtual device yet. This phase proves we can get a clean, timestamped mic feed that AEC3 will later consume as its near-end signal.

Follows PLAN chapters 10 ("Capturing an unprocessed microphone") and 48 ("first PR should contain only raw mic capture").

## Step 1: Permissions plumbing

### Info.plist

Add to `AntiBleedApp/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Anti-Bleed needs microphone access to create the cleaned virtual microphone.</string>
```

No `NSAudioCaptureUsageDescription` yet - that belongs to Phase 2 (system tap). Do not request it early; macOS shows one prompt at a time and bundling them confuses the user.

### Permissions.swift

```swift
enum PermissionState { case notDetermined, granted, denied, restricted }

final class Permissions: ObservableObject {
    @Published var mic: PermissionState = .notDetermined
    func refreshMicStatus()
    func requestMic() async -> PermissionState
    // Phase 2 will add systemAudioTap status
}
```

Rules:

- If denied: do not crash, do not output stale samples. Virtual path outputs silence (PLAN 10.2). Show an actionable error with a button that opens System Settings -> Privacy & Security -> Microphone.
- Polling permission state must not spam the system prompt; call `AVAudioApplication.requestRecordPermission` only on explicit user action.
- Log state transitions (granted/denied) at most once per transition; never per 10 ms frame (PLAN 39).

## Step 2: Device enumeration

### DeviceManager.swift (Phase 1 scope)

```swift
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isInput: Bool
    let sampleRate: Double
    let channelCount: UInt32
}

final class DeviceManager: ObservableObject {
    @Published var inputDevices: [AudioDevice]
    @Published var selectedInputID: AudioDeviceID?
    func refresh()
    func observeDeviceChanges()  // kAudioHardwarePropertyDevices, kAudioDevicePropertyDeviceIsAlive
}
```

Use Core Audio `AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices` and `kAudioDevicePropertyDeviceName` / `kAudioDevicePropertyDeviceUID`. Filter to devices with `kAudioDevicePropertyStreams` in `kAudioDevicePropertyScopeInput`.

- Persist `selectedInputID` (or UID) in `UserDefaults`; on launch, re-resolve UID -> current `AudioDeviceID` (IDs are not stable across reboots).
- If the selected mic disappears: fall back to system default input, emit a notification, and crossfade to the new device when Phase 3+ pipeline exists (Phase 1 can simply switch; no crossfade yet).
- Expose `defaultInputDevice` separately for "follow system default" behavior (optional toggle, off by default in Phase 1).

## Step 3: Capture path - AVAudioEngine first, AUHAL-ready

PLAN 10.1 recommends AUHAL for production but allows `AVAudioEngine.inputNode` for the first spike if voice processing is explicitly disabled. Phase 1 uses AVAudioEngine to move fast, but structures the code so AUHAL can replace it without touching callers.

### MicrophoneCapture.swift

```swift
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    // Output: timestamped 10 ms frames pushed into RawMicRing
    var onFrames: (([AudioFrame]) -> Void)?

    func start(deviceID: AudioDeviceID) throws
    func stop()
    var isRunning: Bool { get }
    var currentFormat: AVAudioFormat { get }
}
```

Implementation details:

```swift
let inputNode = engine.inputNode
// CRITICAL - PLAN 10.1:
try? inputNode.setVoiceProcessingEnabled(false)
// Verify it stuck:
assert(inputNode.voiceProcessingEnabled == false, "Voice Processing must be OFF")

// Select the device (AVAudioEngine uses HAL device ID via AudioUnit property)
try setHALDeviceID(engine.inputNode.audioUnit, deviceID: deviceID)

// Install tap - do NOT do DSP here (PLAN 19: real-time callback rules)
let hwFormat = inputNode.outputFormat(forBus: 0) // device native format
inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
    // MINIMAL work only:
    // 1. copy buffer.floatChannelData into a preallocated staging area
    // 2. capture AudioTimeStamp (time.hostTime, sampleTime) + hostTime
    // 3. push into RawMicRing with metadata
    // 4. return immediately
    self?.ring.push(buffer, hostTime: time.hostTime, sampleTime: time.sampleTime)
}
try engine.start()
```

Hard rules (PLAN 19):

- No malloc/free inside the tap block. Preallocate staging buffers.
- No SwiftUI interaction, no file I/O, no JSON, no logging per frame.
- No blocking mutex - use the `RingBuffer` from Phase 0 (lock-free SPSC).
- Verify `setVoiceProcessingEnabled(false)` is called every time the engine is (re)started; some macOS versions re-enable it after route changes.

### Why AVAudioEngine first

- Faster to prove device selection and 48 kHz conversion.
- AUHAL migration is tracked as a Phase 3 or Phase 5 improvement task. Leave a `// TODO(AUHAL):` and a ticket; do not block Phase 1 on AUHAL if AVAudioEngine meets the acceptance criteria.

## Step 4: Format conversion and 10 ms framing

### FormatConverter.swift + AudioSynchronizer (Phase 1 subset)

Even if the mic natively runs at 44.1 kHz or 48 kHz with varying callback sizes (256, 512, 1024), the pipeline must emit exact 10 ms / 480-sample Float32 mono frames.

```text
inputNode tap (variable size, device rate)
        |
        v
  FormatConverter (resample if needed, channel select/mix)
        |
        v
  FrameAssembler (accumulate to 480-sample boundaries)
        |
        v
  RawMicRing<AudioFrame>   // each frame = 480 x Float32 + hostTime + seq
```

Resampling (PLAN 21):

- If device is already 48 kHz mono: no resampling, just slicing.
- If 44.1 kHz or stereo: use `AVAudioConverter` (or a lightweight streaming resampler) with persistent state - do not create a new converter per block; preserve phase/delay.
- Account for converter latency in `hostTime` propagation.
- Channel handling: prefer channel 0 or a controlled mono mix - do not blindly sum channels (PLAN 8.2).

Frame type:

```swift
struct AudioFrame {
    var samples: [Float]   // exactly 480
    var hostTime: UInt64   // mach_absolute_time
    var sampleTime: Float64
    var sequenceNumber: UInt64
    var rms: Float         // computed once, for meters/diagnostics
}
```

## Step 5: Telemetry and diagnostics (Phase 1 subset)

Expose at least:

```text
Selected microphone:     name + UID + sampleRate + channels
Permission:              granted / denied / notDetermined
Capture running:         yes / no
Mic sample rate:         48000 (or native + converted)
Raw mic RMS:             -inf .. 0 dBFS  (10 ms smoothed)
RawMicRing depth:        frames queued
Dropped frames:          overruns (ring overflow)
Underruns:               should be 0 at this phase
Current hostTime drift:  N/A until Phase 3 (placeholder)
```

Meters must be driven from `rms` computed off the audio thread and published to the UI via `@Published` on a throttled timer (e.g., 30 Hz), never by reading the ring inside `body`.

## Step 6: UI - minimal diagnostics view

Add to `DiagnosticsView.swift` (or a temporary debug window):

```text
Microphone
  [ MacBook Pro Microphone  v ]    <- DeviceManager picker
  Permission: Granted  [Open Settings] (if denied)
  Running: YES  48 kHz Float32 mono  480 samples/10 ms
  Raw RMS: [====----] -22.3 dBFS
  Ring: 4 frames  Dropped: 0
  [ Start ] [ Stop ] [ Record 5s WAV (debug) ]
```

The 5 s WAV dump is dev-only, behind `#if DEBUG`, with a visible recording indicator and auto-delete on next launch (PLAN 38).

## Step 7: Tests

### Unit tests (run on any OS + in CI)

```text
RingBufferTests:        (already in Phase 0, extend for AudioFrame)
FormatConverterTests:
  - 48k mono passthrough (no resample)
  - 44.1k -> 48k resample: sine sweep SNR > 60 dB, no glitches at block boundaries
  - stereo -> mono downmix: L+R / 2, no clipping on correlated signal
FrameAssemblerTests:
  - variable input sizes (128, 256, 512, 1024) -> exact 480 outputs
  - remainder buffering across calls
  - sequenceNumber monotonically increments
  - hostTime interpolated correctly across assembled frames
SignalMetricsTests:
  - RMS of silence = -inf, of full-scale sine approx -3.01 dBFS
  - peak tracking
DeviceManagerTests (mocked Core Audio where possible, else integration):
  - enumeration returns at least one input on a Mac
  - UID persistence survives ID change (mock)
```

### Manual hardware test (on the Mac, with checklist)

```text
1. Launch app, grant mic permission -> Running: YES, RMS meter moves when speaking.
2. Deny permission (System Settings -> revoke) -> app shows "Permission required", no crash, silence path.
3. Switch mic in the picker -> capture restarts, new device name appears, no stale audio.
4. Unplug USB mic (if available) -> fallback to default, no crash.
5. Change system sample rate in Audio MIDI Setup (44.1 <-> 48) -> converter adapts, no clicks.
6. Record 5 s WAV -> open in Audacity -> verify 48 kHz Float32, no voice-processing artifacts (no aggressive gating/compression).
```

## Acceptance criteria

- [ ] `NSMicrophoneUsageDescription` present; app prompts once and handles denied gracefully (silence, actionable error, no crash).
- [ ] Device picker lists all input devices; selecting a device switches capture within 500 ms; choice persists across relaunch.
- [ ] With Voice Processing explicitly disabled, raw capture is unprocessed (no Apple AEC/NS/AGC gating audible; verify by comparing with `voiceProcessingEnabled=true` toggle in a debug build).
- [ ] Pipeline emits exact 480-sample Float32 mono frames at 48 kHz regardless of device native format; `FrameAssemblerTests` green.
- [ ] RMS meter reflects real mic input (speaking moves it, silence near -inf) and does not block the audio thread.
- [ ] Ring under/overrun counters exposed; no unbounded growth in a 10-minute run.
- [ ] `macos-build.yml` still green; new tests added to the run and passing.
- [ ] No per-frame logging, no malloc in the tap block (verified by code review + Instruments Time Profiler showing no allocations in the callback).

## Pitfalls

- Forgetting `setVoiceProcessingEnabled(false)` after every `engine.start()` - macOS can re-enable it after route changes. Re-assert after each start.
- Creating a new `AVAudioConverter` per block - introduces phase discontinuities. Keep one persistent converter per device/format pair.
- Doing DSP or SwiftUI updates inside the tap block - violates real-time rules and causes glitches. Push to ring and return.
- Using `AudioDeviceID` as a persistent key - it is not stable. Persist UID.

## Next phase gate

Phase 2 may start only when raw mic capture is demonstrably unprocessed and stably framed for at least a 10-minute run on a real Mac. The gate is measured, not assumed.
