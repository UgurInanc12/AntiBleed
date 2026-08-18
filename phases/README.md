# Anti-Bleed_mic: Phase Index

> Master specification: ../ANTI_BLEED_MIC_PLAN.md (48 chapters). These phase documents turn that specification into an ordered, verifiable execution plan for one engineer + agent.

## Status board

| Phase | Document | Scope | Status |
|-------|----------|-------|--------|
| 0 | PHASE-0-repo-and-build-skeleton.md | Repository layout, Swift/C++ skeleton, CI - no DSP | NOT STARTED |
| 1 | PHASE-1-raw-microphone-capture.md | Device enumeration, raw mic capture, permission, 48 kHz framing | NOT STARTED |
| 2 | PHASE-2-system-audio-tap.md | Core Audio Process Tap, render reference, permissions | NOT STARTED |
| 3 | PHASE-3-timing-and-aggregate-device.md | Private aggregate device, clock sync, timestamped queues | NOT STARTED |
| 4 | PHASE-4-offline-webrtc-aec3.md | Pinned WebRTC AEC3, offline synthetic tests (Case A-J) | NOT STARTED |
| 5 | PHASE-5-live-aec.md | Live tap+mic -> AEC3, real speaker bleed reduction | NOT STARTED |
| 6 | PHASE-6-blackhole-mvp.md | BlackHole output -> Discord end-to-end MVP | NOT STARTED |
| 7 | PHASE-7-safety-state-machine.md | BYPASS/PROBING/LEARNING/ACTIVE/DEGRADED, coupling detector | NOT STARTED |
| 8 | PHASE-8-custom-virtual-driver.md | Audio Server Plug-in: Anti-Bleed_mic + hidden writer | NOT STARTED |
| 9 | PHASE-9-remove-blackhole-dependency.md | Clean Mac without BlackHole | NOT STARTED |
| 10 | PHASE-10-product-ui-and-recovery.md | Menu-bar UI, meters, diagnostics, auto-recovery | NOT STARTED |
| 11 | PHASE-11-packaging-and-distribution.md | Signing, Hardened Runtime, notarization, installer | NOT STARTED |

Hard rule from PLAN.md chapter 44: Do not start by writing the driver. Prove synchronized AEC first.

## Project constants

```text
Product name:            Anti-Bleed_mic
Visible input device:    Anti-Bleed_mic
Hidden writer device:    Anti-Bleed_internal_writer (kAudioDevicePropertyIsHidden)
Driver bundle:           AntiBleed.driver -> /Library/Audio/Plug-Ins/HAL/
Primary target:          macOS 14.2+
First hardware:          Apple Silicon (Intel after core pipeline works)
Sample rate:             48,000 Hz
Sample type:             Float32
Frame size:              10 ms (480 samples/channel)
AEC capture channels:    1 (mono)
AEC render channels:     1 (mono downmix of stereo reference)
Default AEC config:      AEC=ON, NS=OFF, AGC=OFF, transient=OFF
Reference capture:       Core Audio Process Tap (CATapDescription)
Fallback capture:        ScreenCaptureKit (older macOS - not in v1)
Virtual device impl:     Core Audio Audio Server Plug-in (NOT AudioDriverKit)
AEC engine:              WebRTC APM / AEC3 (pinned WEBRTC_REVISION)
Code repository:         (to be created) github.com/UgurInanc12/AntiBleed  [TBD]
Local workspace (Win):   D:\Hermes\ANTI_BLEED_MIC
Local workspace (Mac):   ~/dev/AntiBleed  (or as chosen on the Mac)
CI:                      GitHub Actions - macos-14+ runner for Swift/C++/driver
Offline harness:         Python + pytest (runs on Windows without a Mac)
```

## Environment model

```text
Build on Mac:    Xcode (latest stable for target macOS) + CLT + depot_tools/GN/Ninja
Build on Win:    Python 3.11 + uv + pytest (DSP harness only; no Xcode)
CI on macOS:     Swift build + C++ build + offline DSP tests + driver compile
CI on Win/Linux: platform-independent C++ DSP tests (optional)
Secrets:         Developer ID certs + notarization creds in GitHub Actions secrets only
Audio privacy:   ALL processing local. No cloud, no upload, no recording by default.
```

## Working loop (every phase)

1. Read the phase document AND the referenced PLAN.md chapters (listed at the top of each phase file).
2. Implement. Mac-specific builds run on the Mac or the macOS CI runner. Windows runs the offline harness + docs.
3. Run the acceptance checks listed at the bottom of the phase document. Every check must produce real command/output evidence. No "should work".
4. Update the status board in this file (flip NOT STARTED -> IN PROGRESS -> DONE with date).
5. Append any new decision to DECISIONS.md (never edit history).
6. Only then start the next phase.

## Ground rules

- All artifacts in English: code, identifiers, comments, commits, docs, UI copy.
- Never push with unconditional force. Only --force-with-lease with a verified HEAD precondition.
- Audio stays local. No cloud API, no telemetry containing audio, no hidden recording.
- Real-time callbacks: no malloc/free, no blocking mutex, no I/O, no UI work, no JSON. Copy -> timestamp -> push to lock-free ring -> return.
- Never virtual_output = rawMic - rawRender. Selectable outputs are only raw / AEC-processed / crossfade / silence.
- AEC3 is the only signal-altering feature enabled by default. NS/AGC off unless spec is intentionally changed.
- Safety: if no stable acoustic coupling is detected, output is raw mic. Never inject an inverted render.
- Do not copy GPL BlackHole source into a proprietary release without resolving licensing.
- Before touching shared infra (Caddy, signing identities), take a backup and verify.
