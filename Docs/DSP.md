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
3. `RenderActivityDetector` (-55 dBFS threshold, 500 ms hangover)
4. `CouplingDetector.push()` every frame, `evaluate()` every 100 ms
5. `SafetyStateMachine.update()` -> rawMic / aecProcessed / crossfade(p) / silence
6. output = mic, cleaned, equal-power mix of the two, or zeros. The render frame is structurally not a candidate (D-008).

## 4. Coupling detector (D-018)

- 8x box decimation (6 kHz), 650 ms history, 400 ms analysis window
- lag search 0..250 ms at 1 ms steps, or +-15 ms around the AEC3 delay estimate at full resolution
- score = (0.45 corr + 0.35 ERLE + 0.20 stability) * (0.5 + 0.5 health), smoothed 0.7/0.3
- Silent render decays the score

## 5. Safety FSM (D-012)

```
STOPPED/ERROR -> silence
BYPASS   : raw. render active and AEC available -> PROBING
PROBING  : raw. score > 0.6 and 3 stable windows -> LEARNING; render off -> BYPASS
LEARNING : raw. score > 0.7, divergence < 0.1, > 300 ms -> ACTIVE (100 ms crossfade)
ACTIVE   : aec. render off -> BYPASS; score < 0.35 or divergence > 0.2 -> DEGRADED (crossfade back)
DEGRADED : raw. score > 0.65 and divergence < 0.05 -> LEARNING; 500 ms timeout -> BYPASS
any      : divergence > 0.3 while ACTIVE/LEARNING -> DEGRADED; route change -> BYPASS immediately
```

## 6. Real-time rules (PLAN 19)

IOProc: downmix to mono into preallocated buffers, `abm_ring_push`, return. DSP thread (`AntiBleedPipeline.dspLoop`): pops blocks, assembles frames, runs the engine, `abm_fifo_push` to the writer. Writer IOProc: `abm_fifo_pop` (silence on underflow). No allocation, locks or logging on either IOProc.
