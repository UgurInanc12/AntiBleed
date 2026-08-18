# Phase 7: Safety State Machine

> PLAN.md chapters: 13, 14, 22, 27, 30, 31.
> Prerequisite: Phase 6 DONE - BlackHole Discord MVP demonstrates bleed reduction, voice preserved, headphones safe (manual).
> Status: NOT STARTED

## Objective

Replace the Phase 5 placeholder gate ("if render silent -> raw") with a full safety state machine that automatically decides raw vs AEC-processed output, protects the invariant "never inject an inverted render," and handles route/divergence failures. This is the system that makes the product safe to ship to users who will plug/unplug headphones, change volumes, and move laptops.

Follows PLAN chapter 13 ("Safety system: prevent inverse desktop audio") - the chapter that defines the state diagram and coupling detector.

## Step 1: State machine

### States (PLAN 13.2)

```text
STOPPED        Pipeline not running.
BYPASS         Output = raw mic. AEC may stay warm internally.
PROBING        Render active; measuring whether a stable speaker->mic path exists.
LEARNING       Coupling appears real; AEC adapting. Output still raw or very conservative blend.
ACTIVE         AEC has enough confidence; output = AEC-cleaned mic.
DEGRADED       Confidence fell; crossfade back to raw, reset/relearn if needed.
ERROR          Critical capture/write failure; output = silence (no stale replay).
```

### State diagram (simplified)

```text
STOPPED -> BYPASS  (pipeline started)
BYPASS  -> PROBING (render activity detected)
PROBING -> LEARNING (coupling evidence stable for N windows)
PROBING -> BYPASS  (no coupling after timeout)
LEARNING -> ACTIVE  (AEC delay stable, ERL/ERLE/divergence healthy for M windows)
LEARNING -> BYPASS  (divergence or coupling lost)
ACTIVE  -> DEGRADED (confidence dip, divergence, or route change)
DEGRADED -> BYPASS  (if confidence not recovered within hysteresis)
DEGRADED -> LEARNING (if confidence recovers)
ANY -> ERROR (fatal I/O failure) -> STOPPED (recovery)
```

### Swift skeleton

```swift
enum AECState { case stopped, bypass, probing, learning, active, degraded, error }

final class SafetyStateMachine: ObservableObject {
    @Published var state: AECState = .stopped
    @Published var couplingConfidence: Float // 0..1
    @Published var aecDelayMs: Int?

    func update(renderActivity: RenderActivity,
                coupling: CouplingResult,
                aecStats: AECStats,
                routeChanged: Bool) -> OutputSelection

    enum OutputSelection { case rawMic, aecProcessed, crossfade(from: OutputSelection, progress: Float), silence }
}
```

## Step 2: Render activity detector (PLAN 13.3)

If the render reference is effectively silent for a configurable hangover period:

```text
output = raw mic
```

No point cancelling nothing. But do not switch on one silent 10 ms frame - use hysteresis.

```swift
struct RenderActivity {
    var isActive: Bool       // debounced: active only if RMS > threshold for 200-500 ms, inactive after 500-1500 ms silence
    var rmsDb: Float
    var peakDb: Float
    var hangoverMs: Int
}
```

Starting tuning values (PLAN 14 - initial, must be tuned from recordings):

```text
render activity window:    200-500 ms
state-enter hysteresis:    ~500 ms
state-exit hysteresis:     ~500-1500 ms
```

Measure RMS/peak per 10 ms frame; apply a short moving average and the hangover timer. Expose the threshold and hangover as diagnostics config, not hard-coded.

## Step 3: Acoustic coupling detector (PLAN 13.4-13.6)

Render being active is NOT sufficient. Example: `YouTube playing through headphones` - render is active but no meaningful bleed exists. The detector must determine whether a stable acoustic path exists using multiple signals.

Candidate metrics (PLAN 13.4):

```text
1. normalized correlation / coherence between delayed render and raw mic
2. stability of the detected correlation delay
3. AEC3 delay_ms
4. AEC3 delay_median_ms
5. AEC3 delay_standard_deviation_ms
6. AEC3 echo_return_loss (ERL)
7. AEC3 echo_return_loss_enhancement (ERLE)
8. AEC3 divergent_filter_fraction
9. AEC3 residual echo likelihood
```

No single metric trusted alone. Use a small ensemble with a confidence score.

### CouplingDetector.swift

```swift
struct CouplingResult {
    var score: Float // 0..1 (0 = no coupling, 1 = strong stable coupling)
    var delayMs: Int?
    var delayStddevMs: Float?
    var correlation: Float
    var stableDelayWindows: Int
}

final class CouplingDetector {
    func update(renderFrames: [Float], micFrames: [Float], aecStats: AECStats) -> CouplingResult
    func reset() // on route change
}
```

### Stable-correlation requirement (PLAN 13.5)

A real echo path should produce:

- a repeatable delay region (not jumping frame-to-frame),
- meaningful correlation persisting over multiple windows,
- coherence above a tuned threshold for at least `N` consecutive windows (e.g., 300-1000 ms analysis window, PLAN 14).

Methods:

- Normalized cross-correlation in the time domain for coarse delay.
- Frequency-domain coherence or GCC-PHAT for robustness (optional; AEC3 already has a delay estimator, so this is a confidence signal, not a replacement - PLAN 13.5).

### Headphone behavior (PLAN 13.6)

```text
system audio reference = active
physical speaker bleed = approximately absent
=> coupling confidence -> low
=> state -> BYPASS
=> Anti-Bleed_mic -> raw mic
```

Do not rely solely on `transportType`. A USB/Bluetooth device might be headphones, a speaker, a dock, or a monitor. Therefore:

```text
device route heuristic = supporting evidence
actual measured acoustic coupling = primary evidence
```

The `transportType` can bias the initial hypothesis (e.g., Bluetooth -> slightly higher bypass prior) but never decide alone.

## Step 4: Crossfade on transitions (PLAN 13.8)

Switching directly between raw and processed buffers creates clicks. Use a controlled crossfade:

```swift
struct CrossFade {
    static func crossfade(from raw: [Float], to processed: [Float], progress: Float) -> [Float]
    // progress: 0 = all raw, 1 = all processed, linear or equal-power
}
// Suggested range: 50-150 ms (5-15 frames at 10 ms). Tune experimentally.
```

Apply on:

- `BYPASS -> ACTIVE` (fade in AEC)
- `ACTIVE -> BYPASS/DEGRADED` (fade out AEC)
- Any divergence-triggered fallback

## Step 5: Divergence fail-safe (PLAN 13.9)

If AEC reports `divergent_filter_fraction` above threshold or the processed signal becomes suspicious (e.g., output RMS >> mic RMS, or correlation statistics collapse):

```text
ACTIVE -> DEGRADED -> BYPASS
```

The failure mode is "speaker bleed returns temporarily," not "voice destroyed or inverted desktop transmitted." Reset AEC asynchronously and re-enter `PROBING`.

## Step 6: Route-change handling (formalized)

On any `kAudioHardwarePropertyDevices` / `kAudioDevicePropertyDeviceIsAlive` notification indicating the selected output or mic changed:

```text
1. Immediately crossfade to raw mic (within one frame).
2. Tear down old tap/aggregate.
3. Create tap for the new physical output.
4. Reset synchronizer state (Step 3 of Phase 3).
5. Reset AEC (aec.reset()) and CouplingDetector.reset().
6. Enter PROBING/LEARNING; activate only after confidence returns.
```

Never continue applying the old room/speaker filter to a new device pair.

## Step 7: Diagnostics surface (Phase 7 adds to the existing DiagnosticsView)

```text
AEC state:                 BYPASS / PROBING / LEARNING / ACTIVE / DEGRADED / ERROR
Coupling confidence:       0.00 .. 1.00  [bar]
Estimated echo delay:      72 ms (median 71 ms, stddev 2.1 ms)
ERL / ERLE:                18.3 dB / 24.7 dB
Divergent filter frac:     0.02
Render activity:           active (RMS -18 dBFS)
Crossfade:                 idle / 60 ms in
Queue depths:              render 3 / mic 4 / out 2
Dropped / underruns:       0 / 0
Transport type:            builtInSpeaker / bluetooth / usb
```

These are throttled (30 Hz) and never logged per-frame.

## Step 8: Tests

### Unit tests

```text
StateMachineTests:
  - render silent 1 s -> BYPASS (even if coupling score was high before)
  - render active + no coupling -> stays BYPASS/PROBING, never ACTIVE
  - render active + stable coupling + healthy AEC -> transitions PROBING->LEARNING->ACTIVE
  - divergence spike -> ACTIVE->DEGRADED->BYPASS
  - route change -> immediate BYPASS + AEC reset flag

CouplingDetectorTests:
  - synthetic: no coupling (mic = voice, render unrelated) -> score < 0.2
  - synthetic: strong coupling (mic = voice + 0.5*render delayed 40 ms) -> score > 0.8 after N windows
  - delay stability: jittery correlation -> score stays low
  - threshold boundary: score hysteresis (enter ACTIVE at 0.7, exit at 0.4)

CrossFadeTests:
  - raw->processed 100 ms: no discontinuity at splice, energy preserved within 1 dB
  - processed->raw: same
```

### Regression - the no-inverse guard (already from Phase 4, now live)

```text
render active, no render component in microphone (headphones or synthetic H)
  =>  output RMS within 0.5 dB of raw
  =>  correlation(render, output) < 0.05
  =>  no 10 ms window where |output - raw| correlates with render above threshold
This test must be run live on hardware (headphones in) and synthetically in CI.
Its failure is a P0.
```

### Hardware tests (Mac, with checklist)

Same matrix as Phase 5 plus explicit coupling transitions:

```text
1. Start with speakers active, far-end playing -> verify ACTIVE after 1-3 s learning.
2. Plug in headphones mid-call -> verify BYPASS within 1.5 s (hysteresis), no inverted audio.
3. Unplug headphones -> verify re-enters PROBING->ACTIVE.
4. Mute system output (volume 0) while far-end digitally still active -> BYPASS (coupling lost).
5. Unmute -> re-probe.
6. Create divergence (max volume + bass-heavy music) -> DEGRADED->BYPASS, then recovery when volume reduced.
7. Rapid output switches (speakers -> BT -> speakers) -> no crash, no stale filter, each switch triggers reset.
```

## Acceptance criteria

- [ ] State machine implements STOPPED/BYPASS/PROBING/LEARNING/ACTIVE/DEGRADED/ERROR with the transitions above; state and confidence published to the UI.
- [ ] Five scenarios verified live with three-track WAVs + listener notes:
  1. render silent -> raw passthrough (no coloration)
  2. headphones + active render -> raw passthrough (no inverse)
  3. speaker coupling -> ACTIVE after learning
  4. disconnect/route change -> safe BYPASS + relearn
  5. divergence -> safe BYPASS + recovery
- [ ] Crossfades on all transitions 50-150 ms, no audible clicks at splice points (WAV splice analysis + listening).
- [ ] No-inverse regression passes both synthetically (CI) and live on hardware (headphones in).
- [ ] All coupling/AEC thresholds are diagnostics-configurable (not hard-coded) and recorded in `Docs/DSP.md` with the tuned values.
- [ ] `macos-build.yml` green; no per-frame logging; state transitions logged once per transition.

## Pitfalls

- Using a single metric (e.g., only `delayMs`) as the coupling decision - must be an ensemble with hysteresis.
- Using `transportType == bluetooth => BYPASS` as the whole detector - real coupling is measured, transport is only a prior.
- Forgetting to `CouplingDetector.reset()` on route change - old correlation state poisons the new device's decision.
- Setting hysteresis too short (state flickers every few frames) or too long (slow to protect). Start at 500/500-1500 ms (PLAN 14) and tune from recordings.
- Not separating "AEC adapting internally" from "which signal is exposed" - AEC stays warm even while output is BYPASS.

## Next phase gate

Phase 8 may start only when the five safety scenarios above are green on real hardware with recorded WAV evidence and no-inverse regression passing in CI and live. Safety is the gate to shipping a driver users will trust.
