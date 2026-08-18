# Anti-Bleed_mic: DSP Notes

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 8, 11, 12, 13, 20, 21, 28, 30, 31.
> Status: stub - filled as phases implement each subsystem.

## 1. Canonical format

```
48,000 Hz / Float32 / 10 ms frames (480 samples/channel) / mono AEC paths
```

Stereo system output is downmixed to mono only for the AEC reference; user playback is untouched.

## 2. AEC engine (WebRTC AEC3)

- Via `AECBridge/` (`AECProcessor` C++ + `AECBridge` ObjC++).
- `ProcessReverseStream(render)` must precede `ProcessStream(mic)` for each 10 ms pair.
- Default: `AEC ON, NS OFF, AGC OFF, transient OFF` (PLAN 12.2). No NS/AGC until spec changes.
- AEC stays warm even when output is BYPASS (warm without exposing artifacts).

Configuration, pin, and offline results are recorded in `phases/PHASE-4-*` and appended here when Phase 4 lands (including `WEBRTC_REVISION`, measured attenuation per case, distortion numbers).

## 3. Synchronization

See `Architecture.md` and `phases/PHASE-3-*`. Summary:

- Preferred: private aggregate device (mic + tap) for clock sync.
- Always: preserve `AudioTimeStamp` (`mHostTime`/`mSampleTime`/`mRateScalar`); pair by `hostTime` with tolerance; stale-frame drop; `bufferSkew` telemetry.
- Resampling preserves continuous state; its delay is included in hostTime accounting.

## 4. Safety and coupling detection

- Render activity detector: RMS + hangover + hysteresis (PLAN 13.3, 14).
- Coupling detector: ensemble of correlation/coherence + AEC3 `delay`/`ERL`/`ERLE`/`divergent_filter_fraction` (PLAN 13.4). Headphone transport is a prior, not a decision.
- Crossfade 50-150 ms on transitions (PLAN 13.8).
- No-inverse guard: render active + no coupling => `output ≈ raw mic`, `correlation(render, output) < 0.05` (PLAN 28.1 H, 31).

## 5. Resampling

Avoid where possible (ideal: 48 kHz throughout). When needed: high-quality streaming resampler, persistent state, resampler delay accounted for in sync metrics, no per-block independent resampling (PLAN 21).

## 6. Offline harness (PLAN 28)

Synthetic:

```
mic(t) = wantedVoice(t) + noise(t) + convolution(render(t), syntheticRoomIR)
```

Cases A-J (fixed echo, delay/amplitude sweeps, reflections, double-talk, render-only, wanted-only, no-coupling, drift, route change) with metrics (RMS, peak, correlation, ERLE, distortion, latency, clipping). Fixtures in `Tests/OfflineFixtures/`.

## 7. Acceptance metrics (PLAN 30)

- Render silent => output ≈ raw (no coloration).
- Headphones/no coupling => output ≈ raw (no inverse).
- Speaker bleed => >= 20 dB reduction representative, stretch 30 dB where acoustics allow.
- Double-talk => user speech intelligible.
- Latency < 50 ms (stretch 30 ms), CPU < 5% Apple Silicon average (optimization target).

## 8. Log - fill after each tuning run

| Date | WEBRTC_REVISION | Change | Case A att. | Case H no-inverse | Double-talk corr. | Notes |
|------|-----------------|--------|-------------|-------------------|-------------------|-------|
|      |                 |        |             |                   |                   |       |
