"""
End-to-end integration through the REAL AEC3 engine plus a faithful Python
mirror of the Swift AntiBleedEngine (coupling detector -> render activity ->
safety FSM -> output selection). This is the closest we get to the live Mac
pipeline without hardware:

    synthetic room: mic = voice + IR * speaker
    -> aec_offline (WebRTC AEC3, real)              [cleaned frames]
    -> coupling detector + safety FSM (mirrors Swift) [rawMic / aec / xfade]
    -> virtual mic output

Scenarios (PLAN 13.8 "five live scenarios"):
  1. speakers playing, real coupling      -> reaches ACTIVE, bleed strongly reduced
  2. headphones (render active, no echo)  -> stays BYPASS/PROBING, output == raw mic
  3. nothing playing                      -> BYPASS, output == raw mic
  4. double talk                          -> ACTIVE, voice preserved, echo reduced
  5. route change mid-call                -> immediate BYPASS then re-activation
"""
import math
import pathlib
import sys

import numpy as np
import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from dsp.coupling_detector import CouplingDetector  # noqa: E402
from dsp.signal_metrics import rms_db  # noqa: E402
from test_aec3_offline import RUNNER, SR, FRAME, run_aec, speech_like, room_ir, echo_of, aligned_corr  # noqa: E402

pytestmark = pytest.mark.skipif(RUNNER is None, reason="aec_offline runner not built")


# ------------------------------------------------------------------ FSM mirror
class FSM:
    """Mirror of AntiBleedApp/Core/SafetyStateMachine.swift (same thresholds)."""

    def __init__(self):
        self.state = "bypass"
        self.frames = 0
        self.transitions = []
        self.ramp_total = 10
        self.ramp_pos = None
        self.ramp_start = 0.0
        self.ramp_target = 0.0
        self.processed_mix = 0.0
        self.silent_frames = 0
        # D-022: sustained contrary evidence, not a single frame.
        self.contrary_frames = 0
        self.exit_confirm_frames = 200
        self.active_min_dwell_frames = 100
        # D-020: far-end silence never releases ACTIVE (0 = no timeout).
        self.active_silence_grace = 0
        self.learning_silence_grace = 500

    def _go(self, s):
        if s != self.state:
            self.transitions.append((self.state, s))
            self.state = s
            self.frames = 0
            self.contrary_frames = 0

    def _ramp(self, to_processed):
        self.ramp_start = self.processed_mix
        self.ramp_target = 1.0 if to_processed else 0.0
        self.ramp_pos = 0

    def _out(self, idle):
        if self.ramp_pos is None:
            self.processed_mix = 1.0 if idle == "aec" else 0.0
            return idle
        p = self.ramp_pos / self.ramp_total
        self.ramp_pos += 1
        if self.ramp_pos >= self.ramp_total:
            self.ramp_pos = None
        self.processed_mix = self.ramp_start + (self.ramp_target - self.ramp_start) * p
        return ("xfade", self.processed_mix)

    def update(self, render_active, score, stable, div, aec_available=True, route_changed=False):
        if route_changed:
            self._go("bypass"); self.ramp_pos = None
            self.processed_mix = 0.0
            self.silent_frames = 0
            self.contrary_frames = 0
            return "raw"
        self.silent_frames = 0 if render_active else self.silent_frames + 1
        if div > 0.3 and self.state in ("active", "learning"):
            self._go("degraded"); self._ramp(False)
        # D-020: no usable AEC -> raw mic, never silence.
        if not aec_available and self.state in ("active", "learning", "probing", "degraded"):
            was_processed = self.processed_mix > 0 or self.ramp_pos is not None
            self._go("bypass")
            if was_processed:
                self._ramp(False)
                return self._out("raw")
            self.ramp_pos = None
            return "raw"
        self.frames += 1
        s = self.state
        if s == "bypass":
            if render_active and aec_available:
                self._go("probing")
            return self._out("raw")
        if s == "probing":
            if not render_active:
                self._go("bypass"); return "raw"
            if score > 0.6 and stable >= 3:
                self._go("learning")
            return "raw"
        if s == "learning":
            if self.silent_frames > self.learning_silence_grace:
                self._go("bypass"); return "raw"
            if render_active and score < 0.3:
                self.contrary_frames += 1
                if self.contrary_frames > self.exit_confirm_frames:
                    self._go("bypass"); return "raw"
            else:
                self.contrary_frames = 0
            if score > 0.7 and div < 0.1 and self.frames > 30:
                self._go("active"); self._ramp(True)
                return self._out("aec")
            return "raw"
        if s == "active":
            if self.active_silence_grace > 0 and self.silent_frames > self.active_silence_grace:
                self._go("bypass"); self._ramp(False); return self._out("raw")
            if div > 0.2:
                self.contrary_frames = 0
                self._go("degraded"); self._ramp(False); return self._out("raw")
            if render_active and score < 0.35:
                self.contrary_frames += 1
                if (self.contrary_frames > self.exit_confirm_frames
                        and self.frames > self.active_min_dwell_frames):
                    self._go("degraded"); self._ramp(False); return self._out("raw")
            else:
                self.contrary_frames = 0
            return self._out("aec")
        if s == "degraded":
            if self.frames > 50:
                self._go("bypass"); return "raw"
            if score > 0.65 and div < 0.05:
                self._go("learning")
            return self._out("raw")
        return "raw"


class RenderActivity:
    def __init__(self, threshold_db=-55, hangover=50):
        self.t = threshold_db; self.h = hangover; self.rem = 0

    def update(self, db):
        if db > self.t:
            self.rem = self.h; return True
        if self.rem > 0:
            self.rem -= 1; return True
        return False


def linear_fade(a, b, p):
    return (1 - p) * a + p * b


def run_pipeline(render, mic, aec_stats_stream=None, route_change_at=None, align=True):
    """Runs the real AEC once over the whole stream (as the live engine does frame by
    frame, AEC is stateful and order-preserving), then walks the frames through the
    detector + FSM exactly like AntiBleedEngine.process().

    With align=True the raw candidate is delayed by the measured AEC latency, as
    AntiBleedEngine does (D-020), so the two candidates describe the same instant.
    """
    cleaned, stats, frame_stats = run_aec(render, mic, per_frame=True)
    if not stats["real_aec"]:
        pytest.skip("runner built without WebRTC")
    lat = measure_aec_latency() if align else 0
    raw = np.concatenate([np.zeros(lat, dtype=np.float32), mic])[: len(mic)] if lat else mic
    n = min(len(render), len(raw), len(cleaned)) // FRAME
    det = CouplingDetector()
    ra = RenderActivity()
    fsm = FSM()
    out = np.zeros(n * FRAME, dtype=np.float32)
    states, outputs = [], []
    last = {"score": 0.0, "stable_windows": 0}
    for i in range(n):
        r = render[i * FRAME:(i + 1) * FRAME]
        m = mic[i * FRAME:(i + 1) * FRAME]
        a = raw[i * FRAME:(i + 1) * FRAME]
        c = cleaned[i * FRAME:(i + 1) * FRAME]
        fs = frame_stats[i]
        aec_stats = {"valid": bool(fs["valid"]), "delayMs": fs["delay_ms"], "erleDb": fs["erle_db"],
                     "divergentFilterFraction": fs["divergent"]}
        div = fs["divergent"]
        active = ra.update(rms_db(r))
        det.push(r, m)
        if i % 10 == 0:  # mirrors AntiBleedEngine.couplingEveryNFrames
            last = det.evaluate(aec_stats)
        sel = fsm.update(active, last["score"], last["stable_windows"], div,
                         route_changed=(route_change_at is not None and i == route_change_at))
        if sel == "raw":
            out[i * FRAME:(i + 1) * FRAME] = a
        elif sel == "aec":
            out[i * FRAME:(i + 1) * FRAME] = c
        else:
            out[i * FRAME:(i + 1) * FRAME] = linear_fade(a, c, sel[1])
        states.append(fsm.state); outputs.append(sel if isinstance(sel, str) else "xfade")
    return out, cleaned, states, outputs, fsm, stats


_AEC_LATENCY = None


def measure_aec_latency():
    """Mirrors EchoCancellerLatency.measure: a short noise burst with a silent
    render, correlated input against output. Cached per session."""
    global _AEC_LATENCY
    if _AEC_LATENCY is not None:
        return _AEC_LATENCY
    rng = np.random.default_rng(20260911)
    n = FRAME * 20
    cap = (rng.standard_normal(n) * 0.05).astype(np.float32)
    out, _ = run_aec(np.zeros(n, dtype=np.float32), cap)
    max_lag = 1440
    a = cap[: n - max_lag].astype(np.float64)
    best, best_lag = 0.0, 0
    for lag in range(max_lag + 1):
        b = out[lag: lag + len(a)].astype(np.float64)
        d = np.sqrt(float(np.dot(a, a) * np.dot(b, b))) or 1e-12
        c = float(np.dot(a, b) / d)
        if abs(c) > abs(best):
            best, best_lag = c, lag
    _AEC_LATENCY = best_lag
    return best_lag


# ------------------------------------------------------------------ scenarios
def test_scenario_1_speakers_with_bleed_reaches_active_and_removes_bleed():
    render = speech_like(8.0, seed=1)
    ir = room_ir(int(0.045 * SR), gain=0.5)
    echo = echo_of(render, ir)
    mic = echo.copy()  # user silent: everything in the mic is bleed
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    active_frac = states.count("active") / len(states)
    tail = slice(-2 * SR, None)
    att = rms_db(mic[tail]) - rms_db(out[tail])
    print(f"S1: active {active_frac:.0%}, transitions {fsm.transitions[:6]}, bleed attenuation {att:.1f} dB")
    assert "active" in states
    assert active_frac > 0.5
    assert att > 15.0
    assert states[-1] == "active"


def test_scenario_2_headphones_no_coupling_stays_raw():
    render = speech_like(6.0, seed=2)
    mic = speech_like(6.0, seed=3, burst_hz=0.8)  # user's voice only, no echo
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    print(f"S2: states {sorted(set(states))}, outputs {sorted(set(outputs))}")
    assert "active" not in states and "learning" not in states
    assert set(outputs) == {"raw"}
    n = len(states) * FRAME
    lat = measure_aec_latency()
    # The raw candidate is the mic delayed by the AEC latency (D-020).
    np.testing.assert_array_equal(out[lat:n], mic[: n - lat])


def test_scenario_3_nothing_playing_is_transparent():
    mic = speech_like(4.0, seed=4)
    render = np.zeros_like(mic)
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    assert set(states) == {"bypass"}
    assert set(outputs) == {"raw"}
    n = len(states) * FRAME
    lat = measure_aec_latency()
    np.testing.assert_array_equal(out[lat:n], mic[: n - lat])


def test_scenario_4_double_talk_keeps_voice_removes_bleed():
    render = speech_like(8.0, seed=5)
    voice = speech_like(8.0, seed=6, burst_hz=0.7)
    ir = room_ir(int(0.050 * SR), gain=0.5)
    echo = echo_of(render, ir)
    mic = (voice + echo).astype(np.float32)
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    assert "active" in states
    tail = slice(-3 * SR, None)
    corr_voice, lag = aligned_corr(voice[tail], out[tail])
    n = len(out[tail]) - lag
    e = echo[tail][:n]; o = out[tail][lag:lag + n]
    corr_echo_out = float(np.dot(e, o) / (math.sqrt(float(np.dot(e, e) * np.dot(o, o))) or 1e-12))
    corr_echo_mic, _ = aligned_corr(echo[tail], mic[tail])
    print(f"S4: corr(voice,out)={corr_voice:.2f} corr(echo,mic)={corr_echo_mic:.2f} corr(echo,out)={corr_echo_out:.2f}")
    assert corr_voice > 0.7
    assert abs(corr_echo_out) < 0.5 * abs(corr_echo_mic)


def test_scenario_5_route_change_drops_to_raw_then_reactivates():
    render = speech_like(10.0, seed=7)
    ir = room_ir(int(0.040 * SR), gain=0.5)
    mic = echo_of(render, ir)
    change_frame = 500  # 5 s
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic, route_change_at=change_frame)
    assert states[change_frame - 1] == "active"
    assert outputs[change_frame] == "raw"
    assert states[change_frame] in ("bypass", "probing")
    assert "active" in states[change_frame + 1:], "must re-activate after route change"
    print(f"S5: re-activated after {states[change_frame:].index('active') * 10} ms")


def test_invariant_output_is_always_convex_mix_of_mic_and_cleaned():
    render = speech_like(3.0, seed=8)
    mic = echo_of(render, room_ir(int(0.03 * SR), 0.5))
    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic, align=False)
    n = len(states) * FRAME
    lo = np.minimum(mic[:n], cleaned[:n]) - 1e-6
    hi = np.maximum(mic[:n], cleaned[:n]) + 1e-6
    assert np.all(out[:n] >= lo)
    assert np.all(out[:n] <= hi)


# --------------------------------------------------- D-020: continuous operation
def test_scenario_6_pause_in_far_end_does_not_drop_processing():
    """The reported bug: the far end goes quiet, the app drops to BYPASS, and the
    audio skips on the way back into LEARNING/ACTIVE. Processing must survive a
    pause instead, so the virtual mic never changes source mid-call."""
    speech = speech_like(20.0, seed=9)
    render = np.zeros_like(speech)
    render[: 6 * SR] = speech[: 6 * SR]          # far end talks
    render[14 * SR:] = speech[14 * SR:]          # ... pauses 8 s ... talks again
    ir = room_ir(int(0.045 * SR), gain=0.5)
    mic = (speech_like(20.0, seed=10, burst_hz=0.7) + echo_of(render, ir)).astype(np.float32)

    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    silent = slice(7 * SR // FRAME, 13 * SR // FRAME)  # well inside the pause
    print(f"S6: transitions {fsm.transitions}, states during pause {sorted(set(states[silent]))}")
    assert "active" in states, "must reach ACTIVE while the far end plays"
    # No state churn during the pause: whatever it was at the pause, it stays.
    assert len(set(states[silent])) == 1
    assert set(states[silent]) == {"active"}
    # And no source switching either.
    assert set(outputs[silent]) == {"aec"}


# --------------------------------------------------- D-022: no state flapping
def test_scenario_8_marginal_coupling_does_not_flap_between_states():
    """The reported bug: the badge cycles probing -> learning -> active
    continuously, with the audio changing source each time.

    Marginal acoustic coupling (a weak echo path, like a quiet room or a low
    speaker volume) puts the coupling score right on top of the FSM thresholds.
    Measured with the REAL AEC at echo gain 0.06: the score spends 16% of frames
    within 0.08 of activeEnter=0.7 and 26% within 0.08 of activeExit=0.35. The
    FSM used to judge each frame independently, so it crossed those boundaries
    over and over (18 state changes in 20 s before D-022).
    """
    render = speech_like(20.0, seed=31)
    ir = room_ir(int(0.012 * SR), gain=0.06)
    mic = (speech_like(20.0, seed=32, burst_hz=0.6) * 0.3 + echo_of(render, ir)).astype(np.float32)

    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    changes = sum(1 for a, b in zip(states, states[1:]) if a != b)
    print(f"S8: {changes} state changes in 20 s, states {sorted(set(states))}")
    assert changes <= 6, f"state flapping: {changes} changes in 20 s"

    # What the user actually hears is the output source chattering.
    src_changes = sum(1 for a, b in zip(outputs, outputs[1:]) if a != b)
    print(f"S8: output source changes {src_changes}")
    assert src_changes <= 8


def test_scenario_9_sustained_coupling_loss_still_leaves_active():
    """The confirm window must not defeat the safety rule it guards: when the
    speakers really stop reaching the mic (headphones plugged in mid-call),
    ACTIVE must still end.

    The cost of D-022 is latency, and it is bounded: exitConfirmFrames is 2 s, so
    allow 2 s of confirmation plus a settling second before demanding the state
    is gone. Bleed is briefly audible during that window, which is the accepted
    trade for not flapping on every marginal dip.
    """
    render = speech_like(20.0, seed=23)
    ir = room_ir(int(0.03 * SR), gain=0.5)
    mic = echo_of(render, ir).astype(np.float32)
    # Halfway through, the echo disappears and only the user's voice remains.
    half = 7 * SR
    mic[half:] = (speech_like(20.0, seed=24) * 0.5)[half:]

    out, cleaned, states, outputs, fsm, stats = run_pipeline(render, mic)
    assert "active" in states[: half // FRAME], "should have engaged before the loss"
    settle = (half // FRAME) + 300          # 3 s after the loss
    tail = states[settle:]
    print(f"S9: states 3 s after the loss {sorted(set(tail))}")
    assert "active" not in tail, "must leave ACTIVE when coupling is really gone"

    # How long did it actually take? Reported so the trade-off stays visible.
    after = states[half // FRAME:]
    left = next((i for i, s in enumerate(after) if s != "active"), None)
    assert left is not None
    print(f"S9: left ACTIVE {left * 10} ms after the echo disappeared")


def test_scenario_7_switching_source_does_not_shift_the_timeline():
    """Why the skip was audible: the raw and AEC candidates must describe the
    same instant, otherwise every switch splices two different points in time.

    Measured with a silent far end, where the AEC is transparent, so the only
    difference between the two candidates is the time shift under test.
    """
    mic = speech_like(6.0, seed=12, burst_hz=0.8)
    render = np.zeros_like(mic)
    cleaned, stats, _ = run_aec(render, mic, per_frame=True)
    if not stats["real_aec"]:
        pytest.skip("runner built without WebRTC")
    lat = measure_aec_latency()
    raw = np.concatenate([np.zeros(lat, dtype=np.float32), mic])[: len(mic)]
    n = min(len(raw), len(cleaned))

    def corr(a, b):
        a = a.astype(np.float64); b = b.astype(np.float64)
        d = math.sqrt(float(np.dot(a, a) * np.dot(b, b))) or 1e-12
        return float(np.dot(a, b) / d)

    aligned = corr(raw[lat:n], cleaned[lat:n])
    unaligned = corr(mic[:n], cleaned[:n])
    print(f"S7: latency {lat} samples ({lat / SR * 1000:.2f} ms), "
          f"aligned corr={aligned:.3f}, unaligned corr={unaligned:.3f}")
    assert lat > 0, "the AEC path has a latency that must be compensated"
    assert aligned > 0.95, "aligned raw and AEC candidates must describe the same instant"
    # The gap between the two is exactly the discontinuity a switch used to cause.
    assert aligned > unaligned + 0.3
