# Anti-Bleed_mic: Testing

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 28, 29, 30, 31, 40, 42.

## 1. What runs where

| Layer | Tool | Windows | Linux CI | macOS |
|---|---|---|---|---|
| DSP + FSM mirrors, fixtures | pytest (`Tests/test_*.py`) | yes | yes | yes |
| Real AEC3 offline cases A-J | pytest + `build/aec/aec_offline` | yes | yes | yes |
| 5 live scenarios (AEC3 + detector + FSM) | `Tests/test_pipeline_integration.py` | yes | yes | yes |
| Swift core (engine, FSM, detector, sync, rings) | `swift test` (59 XCTest) | yes (`Scripts/swift-test-windows.cmd`) | yes | yes |
| AECBridge sanity | `ctest` in `build/aec` | yes | yes | yes |
| Driver ring policy | `ctest` in `build/driver` | yes | yes | yes |
| HAL driver install, tap permission, Discord | manual + `Scripts/install-driver.sh` | no | no | **required** |
| Acoustic bleed reduction on real speakers | hardware matrix below | no | no | **required** |

## 2. Commands

```text
# Python (Windows)
env -u PYTHONPATH uv venv .venv && env -u PYTHONPATH uv pip install -r Tests/requirements.txt
cmake -S AECBridge -B build/aec -G "Visual Studio 16 2019" -A x64 && cmake --build build/aec --config Release
cmake -S AntiBleedDriver -B build/driver -G "Visual Studio 16 2019" -A x64 && cmake --build build/driver --config Release
.venv/Scripts/pytest -q                      # 96 tests
build/aec/Release/AECBridgeTests.exe          # AEC3 sanity
build/driver/Release/SharedRingBufferTests.exe

# Swift core (Windows, winget Swift 6.3 + VS2019 Build Tools + Windows SDK 10.0.22621)
Scripts/swift-test-windows.cmd                # 59 tests

# macOS: everything
Scripts/bootstrap-macos.sh && Scripts/build-app.sh release
```

## 3. Measured results (2026-09-07, Windows, real WebRTC AEC3 v2.1)

Synthetic room: band-limited bursty speech proxy, IR = direct path + 3 reflections, 48 kHz.

| Case | Setup | Result |
|---|---|---|
| A fixed echo | 40 ms delay, gain 0.5 | echo -34.1 dB -> -90.2 dB, **56.1 dB attenuation**, ERLE 16.2 dB reported |
| B delay sweep | 10 / 60 / 120 / 200 ms | 44.3 / 42.9 / 42.9 / 43.1 dB; AEC3 delay estimate 4 / 56 / 116 / 196 ms |
| E double talk | voice + echo | corr(voice,out) 0.78, corr(echo,out) 0.005 (was 0.44 in mic) |
| G render silent | | corr(mic,out) 0.985 at 9.0 ms processing latency |
| H no coupling (headphones) | render active, no echo | corr(render,out) -0.011 (no inverse injection); near-end attenuated 5.8 dB by AEC3 residual suppressor, which is exactly why the FSM keeps raw mic here |
| J route change | IR switch at 5 s | reconverges, 45.6 dB attenuation after switch |

Integration (real AEC3 + detector + FSM mirror):

| Scenario | Result |
|---|---|
| S1 speakers with bleed | bypass -> probing -> learning -> active; 66 % of run in ACTIVE; bleed 61.9 dB down |
| S2 headphones | never leaves bypass/probing; output bit-identical to raw mic |
| S3 nothing playing | bypass only; output bit-identical to raw mic |
| S4 double talk | ACTIVE; voice corr 0.78 kept; echo corr halved |
| S5 route change | raw within the same frame; re-activates afterwards |

Coupling detector on the same signals: coupled 0.94 correlation at 45 ms lag (true 45 ms), score 1.0; headphones score 0.0.

## 4. Hardware matrix (Mac, mandatory before release, PLAN 29)

Record three synchronized tracks per test: raw mic, render reference, cleaned output (debug dumps are opt-in).

| Dimension | Values |
|-----------|--------|
| Speaker volume | 25%, 50%, 75%, high non-clipping |
| Far-end content | male speech, female speech, music, game audio, abrupt SFX, Discord call speech |
| Near-end | silent, continuous speech, intermittent, double-talk, keyboard, room noise |
| Physical | lid angle, desk move, user position, room switch |
| Route | MacBook speakers, wired headphones, Bluetooth, external speakers, HDMI/monitor, mute |

Acceptance: bleed reduced by >= 15 dB on speakers; headphones stay in BYPASS; double-talk intelligible; mic latency < 50 ms end to end; no state flapping faster than 500 ms.

## 5. Mac gate checklist (open)

- [x] `Scripts/build-app.sh` compiles AntiBleedAudio/AntiBleedApp (verified on GitHub macos-14 runner, 2026-09-07: APM + AECBridge + driver + app, 43 Swift + 84 Python tests green at that commit)
- [ ] `sudo Scripts/install-driver.sh` -> `Anti-Bleed_mic` visible, writer hidden
- [ ] System audio permission prompt appears on first start; denial keeps raw mic working
- [ ] Tap exclusion: play a tone through the app itself, verify it is not in the render meter
- [ ] Discord input = Anti-Bleed_mic, remote peer confirms bleed reduction
- [ ] Kill the app mid-call -> Anti-Bleed_mic goes silent (driver underflow), no stale audio
- [ ] D-020 continuity: with speakers as the macOS output, let the far end pause for
      10-20 s mid-call. The badge must stay `Active` (no `Bypass` / `Learning` churn in
      Diagnostics -> Recent transitions) and the peer must hear no skip when speech resumes.
- [ ] D-020 alignment: Diagnostics shows a non-zero path alignment; force a transition
      (mute/unmute the system output) and confirm the peer hears a smooth fade, not a click.
- [ ] D-020 headphones: switch the macOS output to headphones mid-call -> the badge drops
      to `Bypass` with "Raw microphone: output is not ...", and the peer KEEPS HEARING YOU
      (the mic must not go silent); switch back to the speakers -> bleed removal re-engages
      on its own without user action.
- [ ] D-022 no flapping: play music through the speakers at a NORMAL, quiet-ish volume
      (the marginal-coupling case) and watch the badge for a minute. It must settle and
      stay, not cycle probing -> learning -> active. Diagnostics -> Recent transitions
      should gain only a handful of entries, not a stream.
- [ ] D-022 driver detection: with the driver installed, the menu bar must NOT claim it is
      missing, and Diagnostics -> Driver must read `installed`. The mic picker must not
      list any `Anti-Bleed` device.
- [ ] D-023 self-install: on a Mac with no driver, the menu bar shows "Install virtual
      microphone". Click it -> macOS asks for the password ONCE -> within a few seconds
      `Anti-Bleed_mic` appears in System Settings -> Sound and in Discord's input list,
      with no terminal involved. Test this with the app in ~/Downloads too (TCC path).
- [ ] D-023 install while running: with the app already processing, install the driver
      from the button. The pipeline must restart by itself once the writer appears, and
      cleaned audio must actually reach Discord (ask the peer). Before that restart the
      app runs with nowhere to send audio, so a missing restart is a silent failure.
- [ ] D-023 cancel: click Install, then press Cancel in the password dialog. The app must
      report "Installation needs an administrator password. Nothing was changed." and keep
      working, not hang and not re-prompt.
- [ ] D-023 signing: the bundled driver is ad-hoc signed when DEVELOPER_ID is unset. If the
      device never appears, check whether coreaudiod refused to load it:
      log show --last 2m --predicate 'process == "coreaudiod"' | grep -i antibleed
- [ ] D-021 first run: delete `~/Library/Preferences/com.antibleed.app.plist`, launch -> the
      pickers already show the system default mic/speakers and processing starts on its own,
      with no Start press. Reboot -> the app comes back by itself (login item).
- [ ] D-021 window: the menu bar has no dead buttons. `Diagnostics` opens a window that has
      both a Diagnostics and a Settings tab and comes to the front.
- [ ] D-021 re-engage: measured 330 ms in the engine test; confirm by ear that returning from
      headphones to speakers removes bleed again within roughly half a second.
