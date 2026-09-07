# Anti-Bleed_mic: Testing

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 28, 29, 30, 31, 40, 42.

## 1. What runs where

| Layer | Tool | Windows | Linux CI | macOS |
|---|---|---|---|---|
| DSP + FSM mirrors, fixtures | pytest (`Tests/test_*.py`) | yes | yes | yes |
| Real AEC3 offline cases A-J | pytest + `build/aec/aec_offline` | yes | yes | yes |
| 5 live scenarios (AEC3 + detector + FSM) | `Tests/test_pipeline_integration.py` | yes | yes | yes |
| Swift core (engine, FSM, detector, sync, rings) | `swift test` (43 XCTest) | yes (`Scripts/swift-test-windows.cmd`) | yes | yes |
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
.venv/Scripts/pytest -q                      # 84 tests
build/aec/Release/AECBridgeTests.exe          # AEC3 sanity
build/driver/Release/SharedRingBufferTests.exe

# Swift core (Windows, winget Swift 6.3 + VS2019 Build Tools + Windows SDK 10.0.22621)
Scripts/swift-test-windows.cmd                # 43 tests

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

- [x] `Scripts/build-app.sh` compiles AntiBleedAudio/AntiBleedApp (verified on GitHub macos-14 runner, 2026-09-07: APM + AECBridge + driver + app, 43 Swift + 84 Python tests green)
- [ ] `sudo Scripts/install-driver.sh` -> `Anti-Bleed_mic` visible, writer hidden
- [ ] System audio permission prompt appears on first start; denial keeps raw mic working
- [ ] Tap exclusion: play a tone through the app itself, verify it is not in the render meter
- [ ] Discord input = Anti-Bleed_mic, remote peer confirms bleed reduction
- [ ] Kill the app mid-call -> Anti-Bleed_mic goes silent (driver underflow), no stale audio
