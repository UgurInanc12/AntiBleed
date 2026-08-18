# Anti-Bleed_mic: Testing

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 28, 29, 30, 31, 40, 42.
> Status: stub - filled as phases land, with real numbers.

## 1. Automated

### Offline (CI, no Mac required)

- Synthetic mic generation: `mic = wanted + noise + conv(render, IR)` in `Tests/OfflineFixtures/generate.py`.
- Cases A-J (PLAN 28.1): fixed echo, delay/amplitude sweeps, reflections, double-talk, render-only, wanted-only, no-coupling, drift, route change.
- Metrics: RMS, peak, correlation, ERLE, distortion, latency, clipping, no-inverse regression.
- Harness: `pytest Tests/` + `ctest` (AEC3 C++ tests against archived APM).

### Driver/loopback (Mac, requires driver installed)

- Writer->mic sine injection fidelity, underflow silence, overrun drops oldest.

## 2. Hardware matrix (Mac, mandatory - PLAN 29)

Record three synchronized tracks for every test: `raw mic`, `render reference`, `cleaned output`.

| Dimension | Values |
|-----------|--------|
| Speaker volume | 25%, 50%, 75%, high non-clipping |
| Far-end content | male speech, female speech, music, game audio, abrupt SFX, Discord call speech |
| Near-end | silent, continuous speech, intermittent, double-talk, keyboard, room noise |
| Physical | lid angle, desk move, user position, room switch |
| Route | MacBook speakers, wired headphones, Bluetooth, external speakers, HDMI/monitor, mute |

## 3. Edge cases (PLAN 40 - all must have verified expected behavior)

1. volume 0, 2. muted, 3. render paused, 4. wired headphones, 5. BT headphones, 6. external speakers,
7. HDMI audio, 8. output change mid-call, 9. mic change mid-call, 10. mic unplugged, 11. output unplugged,
12. sleep/wake, 13. app restart while Discord is open, 14. Core Audio restart, 15. driver installed but app not running,
16. app running but permissions denied, 17. Discord opened before Anti-Bleed, 18. 44.1 kHz, 19. 48 kHz,
20. CPU spike, 21. render queue underrun, 22. mic queue underrun, 23. sudden volume change,
24. speaker movement / lid change, 25. double-talk, 26. loud music, 27. quiet far-end, 28. output clipping, 29. mic clipping.

## 4. Acceptance metrics (PLAN 30)

- Render silent => `output ≈ raw` (no coloration).
- Headphones/no coupling => `output ≈ raw` (no inverse).
- Speaker bleed => >= 20 dB reduction representative, stretch 30 dB.
- Double-talk intelligible.
- Latency < 50 ms (stretch 30 ms), CPU < 5% Apple Silicon average.

## 5. No-inverse regression (PLAN 31)

`render active, no render component in mic` => output must NOT acquire a render-correlated component. `correlation(render, output) < 0.05`. Run synthetically in CI and live with headphones. Failure is P0.

## 6. Results - fill after each hardware run

| Date | Mac | macOS | Phases covered | Volumes | Contents | Bleed attenuation | Double-talk | No-inverse | Latency | Notes |
|------|-----|-------|----------------|---------|----------|-------------------|-------------|------------|---------|-------|
|      |     |       |                |         |          |                   |             |            |         |       |
