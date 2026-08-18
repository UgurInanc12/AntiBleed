# Phase 10: Product UI and Recovery

> PLAN.md chapters: 15, 17, 18, 19, 24, 25, 26, 27, 30, 39, 40.
> Prerequisite: Phase 9 DONE, clean Mac without BlackHole works via Anti-Bleed_mic.
> Status: NOT STARTED

## Objective

Build the production user interface and automatic recovery so a normal user never needs Terminal or Audio MIDI Setup. After this phase the app is shippable in function, before signing and packaging.

Follows PLAN chapters 25 (Minimal UI), 26 (Permissions UX), 27 (Failure behavior), 24 (Diagnostics).

## Step 1: App shell, menu bar application

Anti-Bleed is a menu bar app, not a dock app.

```swift
// AntiBleedApp.swift
@main
struct AntiBleedApp: App {
    @StateObject var appState = AppState()
    var body: some Scene {
        MenuBarExtra("Anti-Bleed", systemImage: "waveform.badge.mic") {
            MenuBarView().environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environmentObject(appState) }
    }
}
```

Rules:

* `LSUIElement = true` in Info.plist (no dock icon). A regular window is available only via Settings or Diagnostics.
* Launch at login is an opt in toggle (SMAppService, macOS 13+). Do not enable by default without user consent.
* The menu bar extra shows a compact status, the popover shows the full controls.

## Step 2: AppState, single source of truth

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var selectedMicUID: String?
    @Published var selectedOutputUID: String?
    @Published var pipelineState: PipelineState // mirrors SafetyStateMachine.state
    @Published var permissions: Permissions
    @Published var driverHealth: DriverHealth
    @Published var meters: Meters // rawMicRMS, renderRMS, cleanedRMS (throttled 30 Hz)
    @Published var aecStats: AECStats
    @Published var diagnostics: DiagnosticsSnapshot
}
```

* All Core Audio callbacks and the DSP worker publish via `DispatchQueue.main.async` or `MainActor`, never by touching `@Published` off the main thread.
* Meters are throttled, 30 Hz is enough for eyes, and never per 10 ms frame (PLAN 39).

## Step 3: UI surfaces

### MenuBarView, the primary surface (PLAN 25)

```
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

Raw Mic       [ meter -22 dB ]
Speaker Ref   [ meter -18 dB ]
Clean Mic     [ meter -24 dB ]

AEC: Active
Estimated echo delay: 72 ms

[ Test Microphone ]
[ Advanced Diagnostics ]
[ Quit ]
```

State labels must be human readable, not enum names:

```text
Bypass, no speaker echo detected
Learning speaker path
Active
Reconnecting audio device
Permission required
Driver unavailable
```

Do not label ordinary BYPASS as an error. It is the correct state when no coupling exists.

Components:

* `DeviceSelectorView.swift`: two pickers, mic and output, driven by `DeviceManager`. The list updates live when devices appear or disappear. The selected UID is persisted in UserDefaults and re-resolved on launch (IDs are not stable).
* `DiagnosticsView.swift`: advanced panel, hidden by default, revealed by the button above.
* `SettingsView.swift`: launch at login, enable or disable AEC (default ON), reset to defaults.

Design constraints, per user preference:

* No flashing AI slop badges, no animated mesh gradients, no systems operational pills, no duplicate CTAs. Static, matte dark palette, clean typography.
* Growing lists use bounded scroll containers, not infinite page growth.

### DiagnosticsView, development and support

Visible only behind Advanced Diagnostics (PLAN 24):

```text
Selected microphone:          MacBook Pro Microphone (UID ...)
Selected physical output:     MacBook Pro Speakers
Tap status:                   running
Driver:                       AntiBleed.driver 1.2.3  (writer resolved: yes)
Mic sample rate:              48000
Render sample rate:           48000
Virtual sample rate:          48000
Raw mic RMS:                  -22.3 dBFS
Render RMS:                   -18.1 dBFS
Processed mic RMS:            -24.0 dBFS
AEC state:                    ACTIVE
Coupling confidence:          0.87
AEC delay:                    72 ms (median 71, stddev 2.1)
ERL / ERLE:                   18.3 / 24.7 dB
Residual echo likelihood:     0.04
Divergent filter fraction:    0.02
Render queue depth:           3
Mic queue depth:              4
Output queue depth:           2
Dropped render frames:        0
Dropped mic frames:           0
Virtual writer underruns:     0 / overruns: 0
Current latency estimate:     38 ms
Versions: Anti-Bleed 0.9.0 / WebRTC abc1234 / Driver 1.2.3 / macOS 14.4 / arm64
```

Every value from this list is already produced by earlier phases, this phase only surfaces it. Add copy to clipboard for support.

## Step 4: Permissions UX (PLAN 26)

Two independent permissions, each with its own prompt and recovery:

* `NSMicrophoneUsageDescription`: "Anti-Bleed needs microphone access to create the cleaned virtual microphone."
* `NSAudioCaptureUsageDescription`: "Anti-Bleed reads the audio sent to your output device locally so it can remove speaker bleed from your microphone."

UI:

* If mic denied: banner with `Open System Settings` button that calls `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)`.
* If system audio denied: banner with `AEC unavailable, system audio reference lost` and a button that re-triggers the tap permission flow (PLAN 27.1).
* Privacy guarantees shown once on first launch and in Settings: local only, no account, no cloud, no upload, no recording by default, debug dumps require explicit action.

## Step 5: Automatic recovery

The app must recover without user intervention from every condition in PLAN 40 where recovery is possible. Implement watchers:

```swift
final class RecoveryManager {
    func observeDeviceChanges()   // kAudioHardwarePropertyDevices, kAudioDevicePropertyDeviceIsAlive
    func observeRouteChanges()    // output or mic switch, sample rate change
    func observeSleepWake()       // NSWorkspace.screensDidSleep / screensDidWake
    func observeDriverHealth()    // poll writer UID resolvable, ring responsive
}
```

Behaviors, per PLAN 27 and chapter 17/18:

* Output route change: immediately crossfade to raw mic, tear down old tap/aggregate, create tap for new output, reset AEC and coupling detector, re-enter PROBING. Never apply old filter to new device.
* Mic change or unplug: stop writer safely (silence), switch to new raw mic, rebuild aggregate, reset AEC, relearn.
* Sample rate change: rebuild converters and frame assembler, reset skew filter.
* Sleep or wake: stop pipeline on sleep, rebuild everything on wake.
* Driver writer lost: stop pipeline, surface `Driver unavailable`, retry UID lookup every 2 seconds, resume when found.
* Core Audio restart (coreaudiod died): re-enumerate, rebuild taps and aggregate.
* App relaunched while Discord is open: driver underflowed to silence while app was gone, now app reclaims writer and Discord continues without reselecting.

All transitions are visible in Diagnostics (state change log, throttled) and never per frame.

## Step 6: Test Microphone

A one click self test that does not require Discord:

```text
[ Test Microphone ] -> records 5 seconds of:
  raw mic, render reference, cleaned output (three WAVs, same as PLAN 29)
  then shows: RMS levels, coupling confidence, AEC delay, and a playback
  selector (raw vs cleaned) through headphones.
```

This reuses the debug sink from Phase 5 but behind a user facing button. It is the fastest way for a user or support to verify the product.

## Step 7: Tests

### Unit and UI tests

```text
AppStateTests:
  - selected UID persists and re-resolves after ID change (mock)
  - permission denied -> banner state, no crash

DeviceSelectorViewTests (ViewInspector or snapshot):
  - picker lists inputs and outputs, selection updates appState
  - device removal updates list live

RecoveryManagerTests (mocked Core Audio notifications):
  - output switch -> pipeline receives reset + PROBING
  - mic unplug -> pipeline stops writer, surfaces fallback
  - sleep -> pipeline stopped, wake -> pipeline rebuilt

DiagnosticsViewTests:
  - all fields render without crash when pipeline is STOPPED
  - meters update at throttled rate, not per frame
```

### Manual, on the Mac

Run the PLAN 40 edge case matrix and check the UI reflects each correctly:

```text
1.  system volume 0, muted, render paused
2.  wired headphones, Bluetooth headphones, external speakers, HDMI audio
3.  output change mid call, mic change mid call
4.  mic unplugged, output unplugged
5.  sleep/wake, app restart while Discord is open
6.  Core Audio restart (sudo killall coreaudiod)
7.  driver installed but app not running (Discord shows Anti-Bleed_mic, but it outputs silence)
8.  app running but permissions denied
9.  Discord opened before Anti-Bleed (then Anti-Bleed starts, Discord should see the mic)
10. 44.1 kHz and 48 kHz sources
11. CPU load spike, queue under/overruns, sudden volume change
```

Each case has an expected UI state (e.g., `Driver unavailable`, `Permission required`, `Bypass, no speaker echo detected`). Verify the label is correct and not an error when BYPASS is expected.

## Acceptance criteria

* [ ] Menu bar app launches with no dock icon, shows status and pickers, pickers persist across relaunch.
* [ ] DiagnosticsView exposes all fields from PLAN 24, values update live and are copyable.
* [ ] Permission flows for mic and system audio each work independently, with Open System Settings recovery and correct privacy copy.
* [ ] Every route change scenario crossfades to raw mic, resets AEC, and re-probes without crash, verified by the manual matrix above.
* [ ] Sleep/wake, driver loss, and Core Audio restart all recover automatically without user action beyond permission grants.
* [ ] Test Microphone records and plays back raw vs cleaned, proving the pipeline without Discord.
* [ ] No per frame logging, no audio thread UI work, no malloc in callbacks, meters throttled.
* [ ] UI has no AI slop elements, uses the project's matte dark palette and bounded scroll containers where needed.
* [ ] `macos-build.yml` green with new UI targets, `Docs/Permissions.md` and `Docs/Architecture.md` updated to reflect the final UX.

## Pitfalls

* Updating `@Published` from the audio thread, causes SwiftUI crashes or missed updates. Always hop to MainActor.
* Polling devices in a tight loop, wastes CPU and races with notifications. Use Core Audio property listeners.
* Labeling BYPASS as `Error`, users will think the product is broken when it is correctly bypassing on headphones.
* Forgetting `LSUIElement`, the app appears in the dock and confuses the menu bar pattern.

## Next phase gate

Phase 11 may start only when a normal user can install, grant permissions, select devices, see status and meters, survive route changes and sleep/wake, and test the mic without touching Terminal or Audio MIDI Setup. The gate is the manual matrix, all rows checked with screenshots or notes.
