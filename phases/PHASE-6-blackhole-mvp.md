# Phase 6: BlackHole MVP

> PLAN.md chapters: 15, 16, 27, 32.
> Prerequisite: Phase 5 DONE - live AEC demonstrably reduces speaker bleed with real hardware.
> Status: NOT STARTED

## Objective

Route the AEC-cleaned microphone through BlackHole 2ch as a temporary virtual device so a real Discord call can consume it end-to-end. This proves the product behavior before any custom driver is written, isolating the remaining risk (driver) from the already-proven risk (AEC + sync).

Follows PLAN chapter 16 ("BlackHole MVP path") and milestone E. BlackHole is a development-only bridge; it must not become a hidden permanent dependency (PLAN 41).

## Step 1: Install BlackHole 2ch (Mac only, dev dependency)

```bash
# On the Mac:
brew install blackhole-2ch
# or download the installer from https://github.com/ExistentialAudio/BlackHole

# Verify:
system_profiler SPAudioDataType | grep -A2 BlackHole
# or:
SwitchAudioSource -a  # if switchaudio-osx is installed
```

Do NOT add BlackHole as a git submodule. Do NOT copy its source into this repo (GPL-3.0, PLAN 16.1). It is an installed package on the Mac only.

Record the installed version in `Docs/Testing.md`:

```text
BlackHole version: 0.x.x (brew info blackhole-2ch)
```

## Step 2: Audio routing for MVP

```
Core Audio Tap ─┐
                ├─> AntiBleedPipeline (AEC3) ─> BlackHole 2ch (output) ─> Discord (input = BlackHole)
Physical mic  ──┘
```

### VirtualMicWriter.swift (Phase 6 - BlackHole variant)

```swift
final class VirtualMicWriter {
    private var blackHoleDeviceID: AudioDeviceID?

    func resolveBlackHole() throws // find device by UID "BlackHole2ch_UID" or name
    func startWriting() throws     // open HAL output to BlackHole
    func write(frames: [AudioFrame]) // called from DSP worker, NOT from callback
    func stop()
}
```

Implementation:

- Resolve BlackHole by UID (`kAudioDevicePropertyDeviceUID` contains `BlackHole2ch_UID`; verify on the Mac with `Audio MIDI Setup`).
- Open a HAL output stream to BlackHole at 48 kHz Float32 (or the device's native format with conversion).
- The DSP worker pushes cleaned frames (or raw mic when bypassed - Phase 7) into BlackHole via `AudioUnitRender` / `AudioDeviceIOProc` output. Do not do conversion inside the Core Audio callback; pre-convert on the DSP thread.
- Handle underflow: if the app stops writing, BlackHole input must go to silence - never replay the last buffer (PLAN 15.3).

### Discord configuration

```text
Discord -> Settings -> Voice & Video -> Input Device = BlackHole 2ch
```

No Audio MIDI Setup aggregate or multi-output device for the user to configure. The MVP still requires the manual Discord picker change; Phase 9 will replace BlackHole selection with `Anti-Bleed_mic`.

## Step 3: End-to-end test protocol

With the full chain running (`mic + tap -> AEC -> BlackHole -> Discord`):

```text
1. Start Anti-Bleed; confirm BlackHole resolved, pipeline ACTIVE or BYPASS as appropriate.
2. Join a Discord voice channel (or a test call with a second account/device).
3. From the Mac speakers, play:
     - YouTube speech (male/female)
     - music, game audio, abrupt SFX
   At 25/50/75% volume (PLAN 29).
4. Alternate near-end states:
     - user silent (far-end only)
     - user speaking continuously
     - double-talk (far-end speech + user speaking simultaneously)
5. Verify on the remote Discord peer:
     - far-end speaker bleed is substantially reduced (the core claim)
     - user speech is preserved and intelligible (double-talk)
     - no clicks, no periodic glitches, no growing latency
6. Headphones case:
     - Plug in headphones, keep the same far-end content playing.
     - Verify: output approx raw mic, no inverted render injected.
     - Remote peer should hear the user normally, not a suppressed/inverted signal.
7. Record three-track WAVs in parallel (raw mic, render reference, cleaned output) for post-hoc metrics - same as Phase 5, but now also capture Discord's received audio on the remote peer for comparison.
```

## Step 4: Failure behavior (Phase 6 subset of PLAN 27)

Even with BlackHole, the fail-safes from PLAN 27 apply:

- System tap failure -> raw mic to BlackHole, UI shows `AEC unavailable - system audio reference lost`.
- AEC divergence -> raw mic to BlackHole.
- No system audio -> raw mic.
- Headphones/no coupling -> raw mic (even though render is active digitally).
- Mic failure -> silence to BlackHole (no stale replay).
- App crash -> BlackHole underflows to silence (verify: kill the app mid-call, remote peer hears silence, not a loop).

## Step 5: Tests

### Automated (CI + Mac)

```text
BlackHoleWriterTests (Mac only, gated by device presence):
  - resolveBlackHole() finds the device when installed, throws when not
  - write(frames) -> BlackHole input RMS matches expected within 0.5 dB
  - stop() -> BlackHole input goes to silence within 100 ms (no replay)

PipelineToBlackHoleIntegrationTests:
  - full pipeline -> BlackHole: cleaned frames arrive, no underrun storm
  - bypass case -> raw mic forwarded unchanged
```

If BlackHole is not installed (Windows runners, clean Mac), these tests are skipped with a clear message - they do not fail CI. Guard with `if deviceExists("BlackHole2ch_UID")`.

### Manual - the actual product test

The acceptance criteria below are verified by a live Discord call, not by unit tests alone. Someone must sit in the call and listen.

## Acceptance criteria

- [ ] BlackHole 2ch installed on the Mac; `VirtualMicWriter` resolves it by UID and can write 48 kHz Float32 frames without glitches.
- [ ] Selecting `BlackHole 2ch` as Discord's Input Device delivers the AEC-processed mic to the remote peer.
- [ ] With Mac speakers at 50% volume and far-end speech/music playing, remote peer hears speaker bleed substantially reduced (audibly + >= 20 dB on the parallel WAV metrics) while user speech is preserved.
- [ ] Double-talk intelligible on the remote peer.
- [ ] Headphones plugged in with active render: pipeline bypasses to raw mic; remote peer hears no inverted render (live no-inverse check passes).
- [ ] Failure injections (kill tap, kill mic, kill app) produce the correct fallback (raw mic or silence, per PLAN 27) without replaying stale audio.
- [ ] `Docs/Testing.md` updated with the Discord test matrix results (volumes, content types, near-end states, measured attenuation, listener notes).
- [ ] `phases/README.md` and `DECISIONS.md` explicitly note: BlackHole is dev-only; removal is Phase 9.

## Pitfalls

- Forgetting that BlackHole is GPL-3.0. Do not vendor its source, do not fork/rename it for a closed-source release without resolving licensing.
- Letting testers believe BlackHole is the product. The product is `Anti-Bleed_mic` (Phase 8). BlackHole is a scaffold - label it as such in the UI during this phase (e.g., "Output: BlackHole 2ch (dev MVP)").
- Not testing the headphones case. It is the single most important safety test - render active but no acoustic coupling must equal raw mic.
- Testing only with one person talking. Double-talk is where naive AEC fails; test it every run.

## Licensing warning (verbatim from PLAN 16.1)

> BlackHole is GPL-3.0 and its project documentation states that non-GPL projects require a separate license. Therefore: using BlackHole as an installed development dependency is fine for prototyping; do not copy BlackHole source into a proprietary project without resolving licensing; do not mechanically fork/rename BlackHole for a closed-source commercial release; implement the production Audio Server Plug-in from Apple's sample/API documentation or use an appropriately licensed implementation.

## Next phase gate

Phase 7 may start only when a real Discord call through BlackHole demonstrates the product behavior (bleed reduced, voice preserved, headphones safe) with recorded listener notes and WAV metrics. Do not start the safety state machine before the basic path is proven.
