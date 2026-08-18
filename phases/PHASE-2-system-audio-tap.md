# Phase 2: Core Audio System Tap

> PLAN.md chapters: 8, 9, 11, 15, 19, 20, 24, 26, 40, 48.
> Prerequisite: Phase 1 DONE - raw mic capture stable, 480-sample framing proven.
> Status: NOT STARTED

## Objective

Capture the exact digital reference of what macOS sends to the physical output device, using a private Core Audio Process Tap, without muting normal speaker playback and without capturing Anti-Bleed's own internal audio. This is the far-end stream that AEC3 will later consume as `ProcessReverseStream`.

Follows PLAN chapter 9 ("Capturing the actual system-output reference") and chapter 48 Reihenfolge: second PR after raw mic.

## Step 1: System-audio permission

### Info.plist

Add alongside the Phase 1 mic key:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Anti-Bleed reads the audio sent to your output device locally so it can remove speaker bleed from your microphone.</string>
```

Extend `Permissions.swift`:

```swift
final class Permissions: ObservableObject {
    @Published var mic: PermissionState
    @Published var systemAudio: PermissionState  // NEW
    func refreshSystemAudioStatus()
    func requestSystemAudio() async -> PermissionState
}
```

Rules:

- Request mic and system-audio permissions independently; do not chain prompts. macOS may show them sequentially - handle either order.
- If system-audio permission is denied: pipeline falls back to raw-mic bypass (PLAN 27.1), shows `AEC unavailable - system audio reference lost`, and keeps raw mic working. No crash, no fabrication.
- Privacy copy in the UI must state verbatim: processing is local, no upload, no recording by default (PLAN 26).

## Step 2: Physical output enumeration

Extend `DeviceManager.swift`:

```swift
extension DeviceManager {
    @Published var outputDevices: [AudioDevice]   // scope = output
    @Published var selectedOutputID: AudioDeviceID?
    var defaultOutputDevice: AudioDevice? { get }
    func refreshOutputs()
}
```

Use `kAudioHardwarePropertyDevices` + `kAudioDevicePropertyStreams` in `kAudioDevicePropertyScopeOutput`. Also query `kAudioDevicePropertyTransportType` for diagnostics (but do NOT use it as the sole headphone heuristic - PLAN 13.6).

Persist `selectedOutputUID` and re-resolve on launch. If the selected output disappears (unplugged, Bluetooth disconnect): keep raw-mic bypass, emit device-change notification, and wait for user selection or system default.

## Step 3: Core Audio Process Tap

This is the most sensitive subsystem. Read Apple's current documentation before coding:

- `https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps`
- `CATapDescription` - `https://developer.apple.com/documentation/coreaudio/catapdescription`

### SystemAudioTap.swift

```swift
final class SystemAudioTap {
    private var tap: AudioTap?
    private var aggregateDevice: AudioDeviceID?  // private aggregate (Phase 3 creates it; Phase 2 stub creates a minimal one)

    var onRenderFrames: (([AudioFrame]) -> Void)?

    func createTap(for outputDeviceID: AudioDeviceID) throws
    func start() throws
    func stop()
    func destroy()
    var isRunning: Bool { get }
}
```

### Tap configuration goals (PLAN 9.1)

```text
tap visibility:       private
mute behavior:        do not mute normal output (isPrivate = true, muteBehavior = .unmuted)
target device:        selected physical output (not "all devices")
own process:          excluded where appropriate
internal writer:      excluded (Anti-Bleed_internal_writer must never be in the tap's source set)
```

Pseudocode (adapt to the exact API at implementation time - verify signatures in the SDK, not from blog posts):

```swift
let desc = CATapDescription(stereoGlobalTapUnmuted: outputDeviceID)
// Configure: private, unmuted, exclude own process / writer UID
desc.isPrivate = true
// Apple sample: AudioHardwareCreateProcessTap / AudioHardwareCreateAggregateDevice
var tapID: AudioObjectID = 0
let err = AudioHardwareCreateProcessTap(desc, &tapID)
guard err == noErr else { throw TapError.creationFailed(err) }

// Create a minimal private aggregate or direct tap device that vends the tap's stream
// (Phase 3 will replace this with the full mic+tap aggregate; Phase 2 proves a standalone tap works)
```

Reference implementation: Apple's `CaptureSystemAudioWithTaps` sample project. Clone it on the Mac and keep it next to this repo for comparison - do not copy-paste its code verbatim without understanding the lifecycle.

### Real-time callback - same discipline as Phase 1

```swift
// Tap IOProc / tap callback:
tapIOProc(inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime) -> OSStatus {
    // 1. copy Float32 block from inInputData
    // 2. capture inNow (AudioTimeStamp: mHostTime, mSampleTime, mRateScalar)
    // 3. push into RenderReferenceRing with metadata
    // 4. return noErr - do NOT write to outOutputData (we are not replacing output)
}
```

- No malloc, no blocking lock, no I/O, no UI work. Copy -> timestamp -> push -> return.
- Preserve `AudioTimeStamp` fields per block; do not discard timing (PLAN 11.1).
- Push into a dedicated `RenderReferenceRing` (SPSC, bounded, preallocated - same `RingBuffer` from Phase 0).

## Step 4: Format handling (Phase 2 subset)

System output may be stereo at 44.1 or 48 kHz. For AEC MVP:

```text
System tap (stereo, native rate) -> FormatConverter -> mono downmix (L+R)/2 -> resample to 48 kHz if needed -> 480-sample frames
```

- The user's actual playback is untouched - only the AEC reference copy is downmixed/resampled.
- Use a persistent converter per output device/format; do not re-create per block.
- Track `renderSampleRate`, `renderChannelCount`, and resampler delay for telemetry.

## Step 5: Self-reference / feedback avoidance

Critical invariant (PLAN 9.2):

```text
Desired reference:  audio actually intended for speaker/headphone output
NOT:                all audio on all devices including Anti-Bleed's own virtual output
```

Verification:

- The tap must be bound to the selected physical output device, not a global "all devices" tap.
- The Anti-Bleed process and `Anti-Bleed_internal_writer` UID are excluded from the tap's source set where the API allows exclusion. If exclusion is not available in the current OS version, verify by test that writing to the hidden writer does not appear in the tap's captured stream (loopback test in Step 7).
- Document the exact exclusion mechanism used (tap description flags / aggregate composition) in `Docs/Architecture.md`.

## Step 6: Telemetry (additive to Phase 1)

Expose:

```text
Selected physical output:    name + UID + transportType + sampleRate + channels
Tap status:                  notCreated / creating / running / failed (OSStatus)
Tap permission:              granted / denied
Render sample rate:          48000 (or native + converted)
Render RMS:                  -inf .. 0 dBFS  (10 ms smoothed)
RenderReferenceRing depth:   frames queued
Render dropped frames:       overruns
Own-process exclusion:       verified YES/NO (+ method)
```

Drive meters from `rms` published on a 30 Hz timer, never from the audio thread.

## Step 7: Tests

### Unit tests (any OS where mocked, else macOS)

```text
TapDescriptionTests:
  - private+unmuted flags set correctly
  - target device is the selected physical output, not "all"
  - own-process exclusion enumerated
FormatConverterTests (render path):
  - stereo -> mono: (L+R)/2, no clipping on correlated signal
  - 44.1k -> 48k render resample: sine sweep SNR threshold
  - 48k stereo passthrough: no resample
FrameAssemblerTests (render):
  - variable tap callback sizes -> exact 480 outputs
```

### Manual hardware tests (on the Mac)

```text
1. Grant system-audio permission -> Tap status: Running, Render RMS meter moves when YouTube plays.
2. While tap is running, verify normal speaker output still audible (tap must not mute).
3. YouTube pause -> Render RMS falls to -inf within 200-500 ms hangover (render activity detector placeholder).
4. Start writing a test tone to Anti-Bleed_internal_writer (Phase 8 stub or BlackHole writer) -> verify that tone does NOT appear in the RenderReferenceRing (no self-reference loop).
5. Switch physical output (e.g., MacBook Speakers -> AirPods if available) -> tap tears down, new tap for new device appears, no crash.
6. Revoke system-audio permission (if revokable via Settings) -> status -> failed/denied, raw mic keeps working, UI shows AEC unavailable.
7. 10-minute stability run with YouTube playing -> no ring overrun drift, no growing latency.
```

### Loopback self-reference regression (critical)

```text
While the tap is running:
  Play a known 1 kHz tone only via Anti-Bleed_internal_writer (or any hidden output the app owns).
  Assert: RenderReferenceRing does NOT contain a 1 kHz-correlated signal above -60 dBFS.
If it does, the tap is capturing its own output - fix the exclusion before proceeding.
```

## Acceptance criteria

- [ ] `NSAudioCaptureUsageDescription` present; permission granted/denied both handled without crash; denied falls back to raw-mic bypass with actionable message.
- [ ] Physical output picker lists all output devices; selecting a device (re)creates the tap within 500 ms; choice persists across relaunch.
- [ ] With YouTube/Discord playing to the selected output, `Render RMS` meter moves; pausing source returns it to silence within the hangover window; normal speaker output remains audible the entire time.
- [ ] Render pipeline emits exact 480-sample Float32 mono frames at 48 kHz regardless of device native format.
- [ ] Self-reference test passes: writing to the app's own hidden output does not appear in the tap's capture.
- [ ] 10-minute run with continuous render shows bounded `RenderReferenceRing` depth, zero steady overrun growth, no audio glitches attributable to the tap.
- [ ] `macos-build.yml` green with new tap code compiled; no per-frame logging, no malloc in the tap callback.
- [ ] `Docs/Architecture.md` updated with the tap lifecycle diagram and exclusion mechanism used.

## Pitfalls

- Creating a global tap instead of a device-bound private tap - captures everything including the app's own writer and creates a feedback path.
- Forgetting to exclude `Anti-Bleed_internal_writer` - the classic "echo canceller hears itself" bug. The tap must never include the writer.
- Hard-coding a fixed render delay (e.g., 80 ms) as the full sync solution - PLAN 11.4 forbids this. Phase 2 only needs timestamped capture; hard sync is Phase 3.
- Requesting both mic and system-audio permissions in the same call - macOS handles them separately; keep the flows independent.

## Next phase gate

Phase 3 may start only when both streams (raw mic from Phase 1 + render reference from this phase) are independently stable, timestamped, and provably free of self-reference. The gate is the loopback test, not just "it compiles".
