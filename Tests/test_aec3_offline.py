"""
Offline AEC3 tests against the REAL WebRTC engine (PLAN chapter 28, cases A-J).

Requires the native runner built by AECBridge/CMakeLists.txt:
    build/aec/Release/aec_offline(.exe)   (MSVC multi-config)
    build/aec/aec_offline                 (single-config generators)
If the runner is missing or was built without WebRTC, these tests are skipped
with an explicit reason so CI output shows why rather than silently passing.

Signal model (PLAN 2): mic = wanted + noise + conv(render, IR).
"""
import json
import math
import os
import pathlib
import subprocess
import tempfile

import numpy as np
import pytest

from dsp.signal_metrics import rms_db, max_correlation

SR = 48000
FRAME = 480
ROOT = pathlib.Path(__file__).resolve().parent.parent

RUNNER_CANDIDATES = [
    ROOT / "build" / "aec" / "Release" / "aec_offline.exe",
    ROOT / "build" / "aec" / "Release" / "aec_offline",
    ROOT / "build" / "aec" / "aec_offline.exe",
    ROOT / "build" / "aec" / "aec_offline",
]


def _find_runner():
    env = os.environ.get("ANTIBLEED_AEC_RUNNER")
    if env and pathlib.Path(env).exists():
        return pathlib.Path(env)
    for c in RUNNER_CANDIDATES:
        if c.exists():
            return c
    return None


RUNNER = _find_runner()
pytestmark = pytest.mark.skipif(RUNNER is None, reason="aec_offline runner not built (cmake -S AECBridge -B build/aec)")


def run_aec(render: np.ndarray, mic: np.ndarray, delay_hint=None, aec=True, per_frame=False):
    """Runs the native AEC3 over the streams. Returns (out, final_stats) or, with
    per_frame=True, (out, final_stats, frame_stats) where frame_stats is a list of
    dicts (frame, valid, delay_ms, erl_db, erle_db, divergent, residual)."""
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        r, m, o, s = td / "r.f32", td / "m.f32", td / "o.f32", td / "stats.csv"
        render.astype(np.float32).tofile(r)
        mic.astype(np.float32).tofile(m)
        cmd = [str(RUNNER), str(r), str(m), str(o)]
        if delay_hint is not None:
            cmd += ["--delay-hint", str(delay_hint)]
        if not aec:
            cmd += ["--no-aec"]
        if per_frame:
            cmd += ["--stats-out", str(s)]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, f"runner failed rc={res.returncode}: {res.stderr}"
        stats = json.loads(res.stdout.strip().splitlines()[-1])
        out = np.fromfile(o, dtype=np.float32)
        frames = None
        if per_frame:
            import csv
            with open(s, newline="") as fh:
                frames = [{k: (int(v) if k in ("frame", "valid", "delay_ms") else float(v)) for k, v in row.items()}
                          for row in csv.DictReader(fh)]
    return (out, stats, frames) if per_frame else (out, stats)


def _real_engine_or_skip(stats):
    if not stats["real_aec"]:
        pytest.skip(f"runner built without WebRTC: {stats['engine']}")


# ---------------------------------------------------------------- signals
def speech_like(duration, seed, band=(300.0, 3400.0), burst_hz=1.3, level=0.15):
    """Speech-proxy: band-limited noise with on/off syllable-like bursts.
    Stationary sine mixes are avoided on purpose: AEC3 treats stationary tones
    as comfort-noise candidates and the test would measure the wrong thing."""
    rng = np.random.default_rng(seed)
    n = int(duration * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n) * level
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    spectrum[(freqs < band[0]) | (freqs > band[1])] = 0.0
    x = np.fft.irfft(spectrum, n)
    phase = rng.uniform(0, 2 * math.pi)
    env = (np.sin(2 * math.pi * burst_hz * t + phase) > 0).astype(np.float64)
    return (x * env).astype(np.float32)


def room_ir(delay_samples, gain=0.5, reflections=3, seed=0):
    rng = np.random.default_rng(seed)
    ir = np.zeros(delay_samples + reflections * 240 + 1, dtype=np.float32)
    ir[delay_samples] = gain
    for k in range(1, reflections + 1):
        ir[delay_samples + k * 240] = gain * 0.3 / k * rng.choice([-1, 1])
    return ir


def echo_of(render, ir):
    return np.convolve(render, ir, mode="full")[: len(render)].astype(np.float32)


def aligned_corr(ref: np.ndarray, sig: np.ndarray, max_lag=1200):
    """Normalized correlation between ref and sig after compensating the
    processing latency (AEC3 delays capture by ~9 ms). Returns (corr, lag)."""
    ref = ref.astype(np.float64); sig = sig.astype(np.float64)
    n = min(len(ref), len(sig)) - max_lag
    xc = np.correlate(sig[: n + max_lag], ref[:n], mode="valid")  # lag 0..max_lag
    lag = int(np.argmax(np.abs(xc)))
    a, b = ref[:n], sig[lag: lag + n]
    denom = math.sqrt(float(np.dot(a, a) * np.dot(b, b))) or 1e-12
    return float(np.dot(a, b) / denom), lag


def tail(x, seconds=2.0):
    return x[-int(seconds * SR):]


# ---------------------------------------------------------------- cases
def test_case_a_fixed_echo_render_only_is_cancelled():
    """Case A/F: far-end only through a fixed room IR -> AEC must attenuate it."""
    render = speech_like(6.0, seed=1)
    ir = room_ir(delay_samples=int(0.040 * SR), gain=0.5)  # 40 ms acoustic+buffer delay
    mic = echo_of(render, ir)
    out, stats = run_aec(render, mic)
    _real_engine_or_skip(stats)

    before = rms_db(tail(mic))
    after = rms_db(tail(out))
    attenuation = before - after
    print(f"case A: echo {before:.1f} dB -> {after:.1f} dB, attenuation {attenuation:.1f} dB, stats={stats}")
    assert attenuation > 15.0, f"expected >15 dB echo attenuation, got {attenuation:.1f}"
    assert stats["stats_valid"]
    assert stats["divergent_filter_fraction"] < 0.3


@pytest.mark.parametrize("delay_ms", [10, 60, 120, 200])
def test_case_b_delay_sweep(delay_ms):
    """Case B: AEC3 must converge for realistic render->mic delays."""
    render = speech_like(6.0, seed=2 + delay_ms)
    ir = room_ir(delay_samples=int(delay_ms / 1000 * SR), gain=0.45)
    mic = echo_of(render, ir)
    out, stats = run_aec(render, mic)
    _real_engine_or_skip(stats)
    attenuation = rms_db(tail(mic)) - rms_db(tail(out))
    print(f"case B {delay_ms} ms: attenuation {attenuation:.1f} dB, est delay {stats['delay_ms']} ms")
    assert attenuation > 12.0, f"delay {delay_ms} ms: only {attenuation:.1f} dB"


def test_case_e_double_talk_preserves_near_end():
    """Case E: user talks while speaker plays -> echo removed, near-end voice kept."""
    render = speech_like(6.0, seed=10)
    wanted = speech_like(6.0, seed=11, burst_hz=0.7)
    ir = room_ir(delay_samples=int(0.050 * SR), gain=0.5)
    echo = echo_of(render, ir)
    mic = (wanted + echo).astype(np.float32)
    out, stats = run_aec(render, mic)
    _real_engine_or_skip(stats)

    w, o, e = tail(wanted), tail(out), tail(echo)
    # Residual echo: project out onto echo and onto wanted via correlation.
    corr_wanted, lag = aligned_corr(w, o)
    corr_echo_before, _ = aligned_corr(e, tail(mic))
    # Use the same latency for the residual echo measurement.
    n = len(o) - lag
    corr_echo_after = float(np.dot(e[:n], o[lag:lag + n]) / (math.sqrt(float(np.dot(e[:n], e[:n]) * np.dot(o[lag:lag + n], o[lag:lag + n]))) or 1e-12))
    print(f"case E: corr(wanted,out)={corr_wanted:.3f} corr(echo,mic)={corr_echo_before:.3f} corr(echo,out)={corr_echo_after:.3f}")
    assert abs(corr_wanted) > 0.7, "near-end speech destroyed during double-talk"
    assert abs(corr_echo_after) < 0.5 * abs(corr_echo_before), "echo not reduced during double-talk"
    # Level of wanted must survive within a few dB.
    assert rms_db(o) > rms_db(w) - 6.0


def test_case_h_no_coupling_output_stays_raw_and_never_inverted():
    """Case H (D-008 guard): headphones case. Render active, mic has NO echo.
    Output must not acquire any render-correlated component and must not lose level."""
    render = speech_like(4.0, seed=20)
    mic = speech_like(4.0, seed=21, burst_hz=0.9)
    out, stats = run_aec(render, mic)
    _real_engine_or_skip(stats)
    o, m = tail(out), tail(mic)
    corr_render_out, _ = aligned_corr(tail(render), o)
    corr_mic_out, _ = aligned_corr(m, o)
    level_delta = rms_db(m) - rms_db(o)
    print(f"case H: corr(render,out)={corr_render_out:.3f} corr(mic,out)={corr_mic_out:.3f} level loss {level_delta:.2f} dB")
    # Hard invariant (D-008): no render-correlated content may appear at the output.
    assert abs(corr_render_out) < 0.3, "output acquired render content (inverse injection!)"
    # AEC3's residual echo suppressor attenuates near-end when render is active
    # without a coupling path. This is WHY the safety FSM keeps BYPASS in the
    # headphones case (test_pipeline_integration.py). Here we only bound the damage.
    assert corr_mic_out > 0.3, "output no longer resembles the mic at all"
    assert level_delta < 10.0


def test_case_g_render_silent_passthrough():
    """Case G: nothing playing -> AEC must be transparent."""
    mic = speech_like(3.0, seed=30)
    render = np.zeros_like(mic)
    out, stats = run_aec(render, mic)
    _real_engine_or_skip(stats)
    corr, lag = aligned_corr(tail(mic), tail(out))
    print(f"case G: corr={corr:.3f} at processing latency {lag} samples ({lag / SR * 1000:.1f} ms)")
    assert abs(corr) > 0.9
    assert lag < 0.025 * SR, "AEC processing latency exceeds 25 ms budget"
    assert abs(rms_db(tail(mic)) - rms_db(tail(out))) < 2.0


def test_case_j_route_change_reconverges():
    """Case J: the acoustic path changes mid-stream (speaker/volume change).
    AEC3 must re-adapt; residual echo after the switch must fall again."""
    render = speech_like(10.0, seed=40)
    ir1 = room_ir(delay_samples=int(0.040 * SR), gain=0.5, seed=1)
    ir2 = room_ir(delay_samples=int(0.090 * SR), gain=0.35, seed=2)
    half = len(render) // 2
    echo = np.concatenate([echo_of(render[:half], ir1), echo_of(render[half:], ir2)]).astype(np.float32)
    out, stats = run_aec(render, echo)
    _real_engine_or_skip(stats)
    # Window right after the switch vs end of stream.
    after_switch = out[half: half + int(0.5 * SR)]
    settled = out[-int(2.0 * SR):]
    echo_settled = echo[-int(2.0 * SR):]
    att_settled = rms_db(echo_settled) - rms_db(settled)
    print(f"case J: right-after-switch {rms_db(after_switch):.1f} dB, settled {rms_db(settled):.1f} dB, attenuation {att_settled:.1f} dB")
    assert att_settled > 10.0


def test_no_aec_flag_is_true_passthrough():
    """--no-aec must produce bit-identical output apart from HPF-free path (sanity for the runner)."""
    mic = speech_like(1.0, seed=50)
    render = speech_like(1.0, seed=51)
    out, stats = run_aec(render, mic, aec=False)
    corr, _ = aligned_corr(mic, out)
    assert abs(corr) > 0.9
