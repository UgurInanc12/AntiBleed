# Phase 8: Custom Anti-Bleed_mic Virtual Driver

> PLAN.md chapters: 15, 19, 20, 24, 27, 40, 46.
> Prerequisite: Phase 7 DONE - safety FSM green on five live scenarios, no-inverse passing.
> Status: NOT STARTED

## Objective

Replace BlackHole with a native Core Audio Audio Server Plug-in that exposes two devices sharing a driver-side ring buffer: a visible `Anti-Bleed_mic` (input-only, selected by users) and a hidden `Anti-Bleed_internal_writer` (output-only, fed by the app). This is the production virtual microphone.

Follows PLAN chapter 15 ("Virtual microphone design") and D-004/D-005. Do not choose AudioDriverKit - the spec explicitly requires Audio Server Plug-in (Apple documents it as the preferred mechanism for virtual devices).

## Pre-reads (on the Mac, before coding)

- `https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in`
- `https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyishidden`
- `https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver` - read to understand why it is NOT the target.
- Clone Apple's sample `AudioServerPlugIn` (or `NullAudio` / `SimpleAudioDriver` sample) on the Mac as the reference implementation. Keep it unmodified next to this repo for comparison.

## Step 1: Driver project layout

```
AntiBleedDriver/
├── Driver/
│   ├── AntiBleedDriver.cpp / .hpp     # I/O proc, device properties, stream format
│   ├── AntiBleedDevice.cpp / .hpp     # visible device (Anti-Bleed_mic)
│   ├── AntiBleedWriterDevice.cpp/.hpp # hidden writer device
│   ├── AntiBleedPlugIn.cpp / .hpp     # plug-in entry points
│   └── AntiBleedDriver.def            # exports if needed
├── SharedRingBuffer/
│   ├── SharedRingBuffer.hpp           # driver-side SPSC ring, shared by both devices
│   └── SharedRingBuffer.cpp
├── Info.plist                          # kAudioServerPlugInTypeUUID, bundle IDs
├── AntiBleedDriver.xcodeproj or CMake # driver target (builds AntiBleed.driver)
└── README.md
```

### Info.plist essentials

```xml
<key>CFBundleIdentifier</key><string>com.antibleed.driver</string>
<key>CFBundleName</key><string>AntiBleed</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>kAudioServerPlugInTypeUUID</key><string>... (from Apple sample)</string>
```

### Device identities

```text
Visible:  name "Anti-Bleed_mic"
          UID  "com.antibleed.mic"
          isHidden = false, isInput = true, isOutput = false
          streams: 1 input stream, 48 kHz Float32, mono (Phase 9 may add 44.1k if needed)

Hidden:   name "Anti-Bleed_internal_writer" (or UID-only, not user-visible)
          UID  "com.antibleed.writer"
          isHidden = true (kAudioDevicePropertyIsHidden = true)
          isInput = false, isOutput = true
          streams: 1 output stream, 48 kHz Float32, mono
```

The writer's `isHidden` is set via `kAudioDevicePropertyIsHidden` so it does not appear in ordinary device pickers (Discord, System Settings). The app discovers it by UID.

## Step 2: Shared ring buffer

Both devices share the same driver-side memory so writes to the hidden output appear as reads on the visible input without IPC.

```text
Anti-Bleed app
      |
      | Core Audio output writes (AudioDeviceIOProc)
      v
Anti-Bleed_internal_writer   [hidden, output]
      |
      | shared driver ring buffer (lock-free SPSC, preallocated)
      v
Anti-Bleed_mic               [visible, input]
      |
      | Core Audio input reads (AudioDeviceIOProc)
      v
Discord / Zoom / any input client
```

### Requirements (PLAN 15.3-15.4)

- Bounded, preallocated. No malloc in the driver I/O proc.
- Underflow: reader (Anti-Bleed_mic) outputs **silence**, never replays last buffer, never exposes uninitialized memory.
- Overrun: drop oldest stale data; newest real-time mic data is more valuable than preserving old latency (PLAN 15.4).
- Track counters: `underruns`, `overruns`, high-water depth - readable via a driver property for diagnostics.
- Real-time safe: no blocking locks, no allocation, no I/O in the I/O proc.

Reuse the same ring discipline as `DSP/RingBuffer` (Phase 0) but inside the driver context (C++, no Swift, no ARC).

## Step 3: Driver I/O procs

### Writer side (output device)

```cpp
OSStatus WriterIOProc(AudioDeviceID inDevice,
                      const AudioTimeStamp* inNow,
                      const AudioBufferList* inInputData,   // app's cleaned PCM arriving
                      const AudioTimeStamp* inInputTime,
                      AudioBufferList* outOutputData,
                      const AudioTimeStamp* inOutputTime,
                      void* inClientData) {
    // Copy inInputData -> SharedRingBuffer
    // Handle format conversion if the app wrote at a different rate (should be 48k mono; verify)
    // No allocation, no lock, bounded push, increment overruns if full
}
```

### Reader side (input device)

```cpp
OSStatus MicIOProc(AudioDeviceID inDevice,
                   const AudioTimeStamp* inNow,
                   const AudioBufferList* inInputData,
                   const AudioTimeStamp* inInputTime,
                   AudioBufferList* outOutputData,            // Discord reading
                   const AudioTimeStamp* inOutputTime,
                   void* inClientData) {
    // Pop from SharedRingBuffer -> outOutputData
    // On underflow: fill with silence (zeros), increment underruns
    // No replay, no uninitialized memory
}
```

### Latency

The driver's contribution to mic latency must be minimal - the ring is a few frames deep. Measure writer->input latency as part of the acceptance test; include it in the overall `< 50 ms` budget (PLAN 30). Document it in `Docs/Driver.md`.

## Step 4: App-side writer - VirtualMicWriter

Replace the Phase 6 `VirtualMicWriter` (BlackHole variant) with the native writer:

```swift
final class VirtualMicWriter {
    private var writerDeviceID: AudioDeviceID?

    func resolveWriter() throws {
        // Find AudioDevice by UID "com.antibleed.writer"
        // Verify kAudioDevicePropertyIsHidden == true (sanity)
    }
    func startWriting(sampleRate: Double = 48000) throws
    func write(frames: [AudioFrame]) // called from DSP worker, writes via HAL output
    func stop()
    var isResolved: Bool { get }
    var writerLatencyMs: Double { get } // from device property
}
```

- Write path: open a HAL output stream to the hidden writer at 48 kHz Float32 mono. The DSP worker pushes cleaned (or raw, when bypassed) frames via `AudioUnit` / `AudioDeviceIOProc` output.
- On any `AudioHardwarePropertyDevices` change: re-resolve writer UID; if it disappeared, stop writing and surface `Driver unavailable` (PLAN 27.6).
- The tap exclusion from Phase 2 must continue to exclude the writer UID so the driver's own writes never re-enter the tap.

## Step 5: Installation

### Bundle location

```text
/Library/Audio/Plug-Ins/HAL/AntiBleed.driver
```

### Development scripts (Mac only)

```bash
# Scripts/install-driver.sh
#!/bin/bash
set -euo pipefail
DRIVER="AntiBleed.driver"
SRC="build/AntiBleed.driver"
DST="/Library/Audio/Plug-Ins/HAL/$DRIVER"
sudo rm -rf "$DST"
sudo cp -R "$SRC" "$DST"
sudo chown -R root:wheel "$DST"
# Restart Core Audio
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || sudo killall coreaudiod
# Verify
sleep 1
system_profiler SPAudioDataType | grep -q "Anti-Bleed_mic" && echo "Anti-Bleed_mic visible"
```

```bash
# Scripts/uninstall-driver.sh
#!/bin/bash
set -euo pipefail
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || sudo killall coreaudiod
echo "Driver removed. Verify Anti-Bleed_mic no longer appears."
```

Both scripts must fail cleanly if the driver is not present / Core Audio restart fails, and must never remove unrelated audio devices.

Development installer steps (PLAN 15.5) must:

- copy/remove the driver,
- restart Core Audio where appropriate,
- verify `Anti-Bleed_mic` appears,
- verify hidden writer UID lookup succeeds,
- verify Discord can enumerate `Anti-Bleed_mic`.

These checks belong in the script's `verify` step, not as manual afterthoughts.

## Step 6: Tests

### Driver unit tests (Mac only, XCTest or C++ harness where practical)

```text
DriverPropertyTests:
  - Anti-Bleed_mic: isInput=true, isOutput=false, isHidden=false
  - Writer: isInput=false, isOutput=true, isHidden=true
  - UID lookup by "com.antibleed.mic" and "com.antibleed.writer" succeeds
  - Stream format is 48 kHz Float32 mono; verify via kAudioStreamPropertyVirtualFormat

SharedRingBufferTests:
  - push/pop preserves samples, wrap-around, overflow drops oldest, underflow silence
  - concurrent SPSC smoke test (writer thread + reader thread)

WriterToMicLoopTests (requires driver installed):
  - app writes a known 1 kHz sine to writer -> reader (Anti-Bleed_mic) outputs
    the same sine within 1 dB (loopback fidelity)
  - app stops writing -> Anti-Bleed_mic outputs silence within 100 ms (no replay)
  - overrun: fill ring beyond capacity -> oldest dropped, newest delivered, counter increments
```

### Integration - full pipeline through the driver

```text
mic + tap -> AEC -> VirtualMicWriter (writer UID) -> SharedRingBuffer -> Anti-Bleed_mic
  -> (Discord input set to Anti-Bleed_mic) -> remote peer audio
```

Reuse Phase 6's Discord test matrix but with `Anti-Bleed_mic` as the input device instead of BlackHole:

- far-end speech/music on speakers -> remote peer hears bleed reduced
- double-talk intelligible
- headphones plugged in -> bypass to raw mic (no inverse)
- kill app mid-call -> Anti-Bleed_mic outputs silence (driver underflow)

### Negative - hidden writer not user-visible

- Open System Settings -> Sound -> Input and Discord -> Voice & Video -> Input Device; verify `Anti-Bleed_internal_writer` does NOT appear in either picker.
- `system_profiler SPAudioDataType` should show the hidden device only when explicitly listing hidden devices (if the tool supports it) or via UID query - not in the default input list.

## Acceptance criteria

- [ ] `AntiBleed.driver` builds on the Mac (Xcode or CMake) and installs to `/Library/Audio/Plug-Ins/HAL/` via `Scripts/install-driver.sh` without manual `Audio MIDI Setup` configuration.
- [ ] After install + Core Audio restart, `Anti-Bleed_mic` appears as a standard input device (visible in System Settings and Discord).
- [ ] `Anti-Bleed_internal_writer` does NOT appear in ordinary device pickers (verified by UI check + UID query).
- [ ] App resolves writer by UID `com.antibleed.writer`, writes cleaned PCM, and Discord set to `Anti-Bleed_mic` receives it.
- [ ] Writer->reader latency measured and stable; overall mic latency still < 50 ms including driver.
- [ ] Underflow outputs silence (no replay, no uninitialized memory); overrun drops oldest (newest preserved); counters exposed in diagnostics.
- [ ] Discord end-to-end through `Anti-Bleed_mic` reproduces Phase 6 quality: bleed reduced, double-talk intelligible, headphones safe.
- [ ] Uninstall removes driver cleanly without touching other audio devices; Core Audio recovers without reboot.
- [ ] `macos-build.yml` builds the driver target; `Docs/Driver.md` updated with architecture, I/O procs, ring policy, and latency numbers.

## Pitfalls

- Using AudioDriverKit for a purely virtual mic - the spec forbids choosing it "merely because it sounds newer" (PLAN 41).
- Forgetting `kAudioDevicePropertyIsHidden` on the writer - exposes an extra output device that confuses users and may be captured by the tap.
- Letting the tap include the writer's output - recreates the Phase 2 self-reference bug. Verify exclusion after the driver is installed.
- Allowing the driver to replay stale audio on underflow - must be silence (PLAN 15.3).
- Checking the driver bundle into git - it is a build artifact. Only sources are committed.

## Next phase gate

Phase 9 may start only when `Anti-Bleed_mic` is selectable in Discord via the native driver, the hidden writer is correctly hidden, and a Discord call through the driver matches BlackHole MVP quality with no regressions.
