# Phase 5: Live AEC

> PLAN.md chapters: 11, 12, 19, 20, 22, 23, 24, 28, 29, 30, 31, 40.
> Prerequisite: Phase 4 DONE - offline AEC3 passes cases A-J, no-inverse guard green.
> Status: NOT STARTED

## Objective

Wire the live capture streams (Phase 1-3) into the real AEC3 engine (Phase 4) and prove that actual Mac speaker bleed is audibly and measurably reduced while near-end speech stays intelligible. No virtual device or Discord routing yet - output goes to a debug sink (file/headphones) for controlled measurement.

Follows PLAN chapters 32 (Phase 5 "Live AEC") and 42 (Milestone C).

## Step 1: Pipeline wiring - AntiBleedPipeline

### AntiBleedPipeline.swift (Phase 5 - first live integration)

```swift
final class AntiBleedPipeline: ObservableObject {
    // Inputs (owned elsewhere, injected)
    let micCapture: MicrophoneCapture
    let systemTap: SystemAudioTap
    let synchronizer: AudioSynchronizer
    private let aec: AECBridge
    private let dspThread: DSPThread

    // Output (Phase 5: debug sink only)
    var debugSink: DebugSink? // file writer / headphone monitor

    // Telemetry
    @Published var aecStats: AECStats
    @Published var pipelineState: PipelineState // .bypass/.learning/.active (stub; Phase 7 replaces with full FSM)

    func start() throws
    func stop()
}
```

Pseudocode for the DSP worker (high-priority thread, NOT main, NOT callback):

```text
while running {
    guard let (render, mic) = synchronizer.pullAlignedFrames() else {
        // underflow: count it, short sleep, continue
        continue
    }
    // 1. render -> AEC reverse stream (MUST precede capture)
    aec.processRenderFrame(render.samples, numSamples: 480)
    // 2. mic -> AEC capture stream, get cleaned output
    var cleaned = [Float](repeating: 0, count: 480)
    aec.processCaptureFrame(mic.samples, numSamples: 480, out: &cleaned)
    // 3. update stats (delay, ERL/ERLE, divergence) - throttled, not per-frame log
    stats = aec.getStats()
    // 4. Phase 5 output: still the pipeline decides raw vs cleaned.
    //    Start with a simple gate: if render RMS < silenceThreshold for 500 ms -> raw mic
    //    otherwise -> cleaned. Phase 7 replaces this with the full state machine.
    let out = shouldBypass ? mic.samples : cleaned
    debugSink?.write(out, hostTime: mic.hostTime)
    // 5. update meters (RMS of render/mic/cleaned) on a 30 Hz timer
}
```

Rules:

- `processRenderFrame` must be called before the corresponding `processCaptureFrame` (PLAN 12.1).
- No allocation in the hot loop - `cleaned` is a reused buffer.
- If `synchronizer` returns `nil` (underflow), do not feed AEC with stale data. Count underruns and skip.
- On any device removal or sample-rate change: stop worker, reset AEC (`aec.reset()`), drop rings, rebuild aggregate (Phase 3), then restart - never apply an old echo path to a new device pair.

### Configuration (Phase 5)

Same conservative defaults as Phase 4 (PLAN 12.2):

```text
AEC: ON, NS: OFF, AGC: OFF, transient: OFF, VAD: diagnostics only
```

Do not enable NS/AGC to mask live artifacts. If live output sounds noisy, the fix is AEC tuning and sync - not adding a suppressor.

## Step 2: Debug sink (visible indicator required)

Because no virtual device exists yet, live output is observed via a debug sink only:

- **File sink** (`DebugFileSink`): writes 48 kHz Float32 WAV with a visible "Recording debug dump" indicator in the UI and a one-click delete. Disabled by default, opt-in per session (PLAN 38).
- **Headphone monitor** (optional, for direct listening): route cleaned output to a selected headphone output for A/B comparison. Use only when debugging - not the normal path.

Both sinks must:

- Show a persistent indicator while active (no hidden recording).
- Be behind `#if DEBUG` or an explicit "Developer mode" toggle.
- Never be the default on a release build.

For measurement, record three synchronized tracks during each test (PLAN 29):

```text
1. raw microphone  (pre-AEC)
2. system render reference (the tap stream fed to AEC)
3. cleaned output  (post-AEC)
```

These three WAVs are the evidence for every acceptance check below.

## Step 3: Latency and drift sanity

- Target additional mic latency `< 50 ms`, stretch `< 30 ms` (PLAN 30). Measure with a loopback click: play a click to the speaker, capture raw vs cleaned, cross-correlate to find the pipeline delay.
- Verify drift stays bounded during a live run: `bufferSkew` within +/- 10 ms, queue depths not growing, no periodic glitches.

## Step 4: Tests

### Unit / integration (CI where possible, else Mac)

```text
PipelineWiringTests:
  - synchronized pair -> render fed before capture, no crash
  - underflow -> AEC not fed stale data, counter increments
  - device removal -> pipeline stops cleanly, AEC reset called
  - silence gate -> render silent 500 ms => output == raw mic (within 0.5 dB)
```

### Hardware matrix (on the Mac - mandatory, PLAN 29 and 40)

All tests record the three-track WAV set and compute metrics (RMS, correlation, ERLE-like attenuation).

#### Speaker tests - vary output volume

```text
25% volume, 50% volume, 75% volume, high but non-clipping
Each with: male speech, female speech, music, game audio, abrupt SFX
```

#### Near-end tests

```text
- user silent (far-end only)
- user speaks continuously
- user speaks intermittently
- user speaks over far-end (double-talk - the critical case, PLAN 22)
- keyboard typing while far-end plays
- room noise while far-end plays
```

#### Physical changes

```text
- laptop lid angle change
- move laptop on desk
- move user position
- switch room (if available)
```

Per-test checklist:

```text
1. Start pipeline, confirm AEC stats appear (delayMs becomes stable within 1-3 s).
2. Play far-end content at the target volume.
3. Alternate near-end conditions (silent / speaking / double-talk).
4. Record 30-60 s per condition to the three-track WAV set.
5. Compute: render suppression (dB), wanted preservation (correlation), no-inverse check, clipping count.
6. Note any divergence (divergentFilterFraction rising) or instability.
```

## Step 5: Tuning knobs (record, do not hard-code prematurely)

Phase 5 is where real room/speaker/mic behavior forces tuning. Keep every threshold in a diagnostics config (file or `UserDefaults` suite, not hard-coded constants):

```text
render silence RMS threshold
render activity hangover (ms)
initial AEC learning period (1-3 s)
crossfade on bypass (Phase 7, but placeholder)
resampler quality
```

Tune against the hardware matrix, not against one demo recording.

## Acceptance criteria

- [ ] `AntiBleedPipeline` wires `systemTap -> AEC reverse` and `raw mic -> AEC capture` with correct 10 ms ordering; underflow does not feed stale data.
- [ ] With real Mac speakers at 50% volume and far-end speech playing, speaker bleed is audibly reduced and the three-track WAVs show >= 20 dB echo reduction in representative conditions (PLAN 30 core correctness).
- [ ] Double-talk case: user speech remains intelligible while far-end is suppressed (correlation(wanted, cleaned) > 0.8 and listening test passes). No `if mic loud -> disable AEC` logic (PLAN 22).
- [ ] Render-silence case: output approx raw mic (within 0.5 dB, no coloration), no render-correlated component injected - the live no-inverse check.
- [ ] High volume / clipping case degrades gracefully (PLAN 23): AEC not claimed to hit 100% at max volume with bass distortion; near-end not destroyed.
- [ ] AEC not diverged: `divergentFilterFraction` stays < 0.1 during normal conditions; if it rises, pipeline would eventually bypass (Phase 7 formalizes, Phase 5 at least logs it).
- [ ] Additional pipeline latency measured and < 50 ms; method and result recorded in `Docs/Testing.md` or `Docs/DSP.md`.
- [ ] 30-minute live run with continuous far-end shows bounded queues, stable `delayMs`, no periodic glitches.
- [ ] `macos-build.yml` green; no per-frame logging, no malloc in audio callbacks or the hot DSP loop.

## Pitfalls

- Feeding AEC capture before render for the same 10 ms window - violates PLAN 12.1 and collapses delay estimation.
- Feeding stale frames on underflow to "keep AEC busy" - corrupts the filter. Skip on underflow.
- Enabling NS/AGC to hide live artifacts - masks the real problem (sync/delay) and adds a second variable. Fix sync first.
- Testing only at one volume with one content type - PLAN 29 requires a volume and content matrix. Speaker nonlinearity at high volume is expected (PLAN 23).
- Not recording the three-track WAVs - without them, failures are not diagnosable.

## Next phase gate

Phase 6 may start only when live speaker bleed is demonstrably reduced (audibly + >= 20 dB on the WAV metrics) and double-talk preserves near-end speech on real hardware. The gate is the hardware matrix, not the offline tests.
