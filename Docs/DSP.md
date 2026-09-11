# Anti-Bleed_mic: DSP Notes

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 8, 11, 12, 13, 20, 21, 28, 30, 31.

## 1. Canonical format

```
48,000 Hz / Float32 / 10 ms frames (480 samples/channel) / mono AEC paths
```

Stereo system output is downmixed to mono only for the AEC reference; user playback is untouched.
`FrameAssembler` (Swift) turns any callback size / rate / channel count into exact frames with an
interpolated host time per frame; 44.1 kHz devices are resampled with a phase-continuous linear
resampler (measured: 1 kHz tone survives with RMS within 3 %, no clicks).

## 2. AEC engine (WebRTC AEC3 via webrtc-audio-processing v2.1)

- `AECBridge/AECProcessor.{hpp,cpp}`: C++ wrapper around `webrtc::AudioProcessing`. Config: `echo_canceller.enabled`, HPF on, NS/AGC1/AGC2/transient off, `maximum_internal_processing_rate = 48000`.
- `AECBridge/aec_c_api.h`: C ABI used by Swift (`WebRTCCanceller`) through the `AECBridgeC` module.
- Order per frame: `processRenderFrame` (ProcessReverseStream) then `processCaptureFrame` (ProcessStream).
- On any APM error the capture frame is copied through unchanged; the processor never outputs silence or an inverted render.
- Processing latency measured at 430 samples (9.0 ms) at 48 kHz.
- Statistics exposed: delay, ERL, ERLE, divergent filter fraction, residual echo likelihood. Only `delay_ms`, `erl`, `erle`, `divergent` are populated by this APM version; `delay_median/stddev` stay -1.

Build: `Scripts/build-webrtc.sh` (Meson). Windows: see Docs/Testing.md. The library is ~38 MB static.

## 3. Engine (`AntiBleedApp/Core/AntiBleedEngine.swift`)

Per aligned (render, mic) pair:

1. render -> AEC reverse stream (always, keeps the filter warm in BYPASS, PLAN 12.3)
2. mic -> AEC capture stream -> cleaned
3. raw candidate = mic delayed by the AEC's own latency (D-020)
4. `RenderActivityDetector` (-55 dBFS threshold, 500 ms hangover)
5. `CouplingDetector.push()` every frame, `evaluate()` every 100 ms (fed the undelayed mic and render)
6. `SafetyStateMachine.update()` -> rawMic / aecProcessed / crossfade(p) / silence
7. output = aligned raw, cleaned, linear mix of the two, or zeros. The render frame is structurally not a candidate (D-008).

## 3a. Path alignment (D-020)

The APM's output lags its own input by a fixed amount (measured 430 samples / 8.96 ms at 48 kHz, constant across silence, active render and double talk). `EchoCancellerLatency.measure` finds it at startup with a 100 ms internal noise burst against a silent render and `DelayLine` delays the raw candidate to match, so a BYPASS <-> ACTIVE switch is a gain change instead of a ~9 ms jump in the timeline. Cost: 9 ms of extra latency while in BYPASS.

## 4. Coupling detector (D-018)

- 8x box decimation (6 kHz), 650 ms history, 400 ms analysis window
- lag search 0..250 ms at 1 ms steps, or +-15 ms around the AEC3 delay estimate at full resolution
- score = (0.45 corr + 0.35 ERLE + 0.20 stability) * (0.5 + 0.5 health), smoothed 0.7/0.3
- Silent render decays the score

## 5. Safety FSM (D-012, D-020)

```
STOPPED/ERROR -> silence
BYPASS   : raw. render active and AEC available -> PROBING
PROBING  : raw. score > 0.6 and 3 stable windows -> LEARNING; render off -> BYPASS
LEARNING : raw. score > 0.7, divergence < 0.1, > 300 ms -> ACTIVE (100 ms crossfade)
           silence tolerated for 5 s; score is only judged while render is active
ACTIVE   : aec. held through far-end silence indefinitely (the AEC is transparent
           with no render to cancel, so switching back would only be audible;
           activeSilenceGraceFrames = 0 disables the timeout entirely)
           render active and (score < 0.35 or divergence > 0.2) -> DEGRADED (crossfade back)
           divergence > 0.2 -> DEGRADED even during silence
DEGRADED : raw. score > 0.65 and divergence < 0.05 -> LEARNING; 500 ms timeout -> BYPASS
any      : divergence > 0.3 while ACTIVE/LEARNING -> DEGRADED; route change -> BYPASS immediately
```

Above the FSM, the app tells the engine whether the selected reference output is the
one macOS currently plays through (`AppState.pauseWhenOutputNotDefault` ->
`setReferenceOutputActive`). While it is not, the engine holds BYPASS and passes the
raw microphone through: that is the handling of the headphones case, where AEC3
attenuates the near-end voice by ~6 dB. The pipeline keeps running throughout, so the
virtual mic never goes silent mid-call, and the AEC keeps adapting so re-selecting the
speakers converges immediately.

## 6. Real-time rules (PLAN 19)

IOProc: downmix to mono into preallocated buffers, `abm_ring_push`, return. DSP thread (`AntiBleedPipeline.dspLoop`): pops blocks, assembles frames, runs the engine, `abm_fifo_push` to the writer. Writer IOProc: `abm_fifo_pop` (silence on underflow). No allocation, locks or logging on either IOProc.
