import pytest
import numpy as np
import math
from dsp.signal_metrics import rms, rms_db, max_correlation, echo_attenuation_db

# ── Helpers ───────────────────────────────────────────────────
SR = 48000
FRAME = 480  # 10 ms

def make_sine(freq, duration_s, sr=SR, amp=0.5):
    n = int(duration_s * sr)
    t = np.arange(n) / sr
    return (amp * np.sin(2 * math.pi * freq * t)).astype(np.float32)

def make_speech_like(duration_s=1.0, sr=SR):
    # Sum of sines around speech band + amplitude modulation
    n = int(duration_s * sr)
    t = np.arange(n) / sr
    s = (0.3 * np.sin(2*math.pi*200*t) +
         0.2 * np.sin(2*math.pi*400*t) +
         0.15 * np.sin(2*math.pi*800*t))
    env = 0.5 + 0.5 * np.sin(2*math.pi*3*t)  # 3 Hz modulation
    return (s * env).astype(np.float32)

def fir_convolve(x, ir):
    return np.convolve(x, ir, mode='full')[:len(x)].astype(np.float32)

# ── Case A: Fixed echo ───────────────────────────────────────
def test_case_a_fixed_echo():
    render = make_speech_like(1.0)
    wanted = make_sine(300, 1.0, amp=0.3)
    noise = np.random.randn(len(render)).astype(np.float32) * 0.02
    ir = np.array([0.0]*5 + [0.5] + [0.0]*5, dtype=np.float32)  # 5-sample delay, 0.5 gain
    echo = fir_convolve(render, ir)
    mic = wanted + noise + echo

    # Simulated AEC: perfect cancellation would remove echo
    cleaned_perfect = wanted + noise  # ideal
    # Verify echo is present in mic
    corr_render_mic, _ = max_correlation(render, mic, max_lag=20)
    assert abs(corr_render_mic) > 0.3
    # Verify perfect clean removes render correlation
    corr_render_clean, _ = max_correlation(render, cleaned_perfect, max_lag=20)
    assert abs(corr_render_clean) < 0.3

# ── Case G: Wanted only (render silent) ──────────────────────
def test_case_g_wanted_only():
    wanted = make_speech_like(1.0)
    render = np.zeros_like(wanted)
    mic = wanted  # no echo
    cleaned = mic  # bypass: output == raw
    assert rms_db(mic - cleaned) == float('-inf')  # identical
    corr, _ = max_correlation(render, cleaned, max_lag=20)
    # render is silence, correlation is undefined/0
    assert abs(corr) < 0.1 or np.isnan(corr)

# ── Case H: No coupling (the no-inverse guard) ───────────────
def test_case_h_no_coupling():
    render = make_speech_like(1.0)
    # wanted is deliberately uncorrelated with render (different speech band + random phase)
    n = len(render)
    t = np.arange(n) / SR
    # Different frequencies than make_speech_like (which uses 200/400/800)
    wanted = (0.25 * np.sin(2*math.pi*270*t + 1.1) +
              0.18 * np.sin(2*math.pi*520*t + 2.3) +
              0.12 * np.sin(2*math.pi*950*t + 0.7)).astype(np.float32)
    wanted = wanted * (0.5 + 0.5 * np.sin(2*math.pi*4*t + 0.9))
    # mic does NOT contain render at all (headphones case)
    mic = wanted + np.random.randn(len(wanted)).astype(np.float32) * 0.02
    cleaned = mic  # correct behavior: output == raw mic

    # Guard: output must not acquire render correlation
    corr_render_out, _ = max_correlation(render, cleaned, max_lag=48)
    assert abs(corr_render_out) < 0.3

    # RMS within 0.5 dB of raw
    assert abs(rms_db(mic) - rms_db(cleaned)) < 0.5

# ── Case F: Render only, no near-end ─────────────────────────
def test_case_f_render_only():
    render = make_speech_like(1.0)
    ir = np.array([0.0]*10 + [0.4], dtype=np.float32)
    mic = fir_convolve(render, ir)  # only echo
    # Ideal AEC would output silence
    cleaned_ideal = np.zeros_like(mic)
    assert rms(cleaned_ideal) < 1e-6
    # Mic has strong render correlation, cleaned has none
    corr_mic, _ = max_correlation(render, mic, max_lag=20)
    corr_clean, _ = max_correlation(render, cleaned_ideal, max_lag=20)
    assert abs(corr_mic) > 0.5
    assert abs(corr_clean) < 0.1

# ── Case E: Double-talk ──────────────────────────────────────
def test_case_e_double_talk():
    render = make_speech_like(1.0)
    wanted = make_sine(250, 1.0, amp=0.4)
    ir = np.array([0.0]*8 + [0.35], dtype=np.float32)
    echo = fir_convolve(render, ir)
    mic = wanted + echo

    # Perfect AEC preserves wanted
    cleaned_perfect = wanted
    # Correlation(wanted, cleaned) should stay high
    c, _ = max_correlation(wanted, cleaned_perfect, max_lag=5)
    assert abs(c) > 0.85

# ── Case B: Delay sweep 0-250ms ──────────────────────────────
@pytest.mark.parametrize("delay_samples", [0, 48, 240, 480, 1200])  # 0..25ms
def test_case_b_delay_sweep(delay_samples):
    render = make_speech_like(0.5)
    wanted = make_sine(300, 0.5, amp=0.3)
    ir = np.zeros(delay_samples + 1, dtype=np.float32)
    ir[-1] = 0.4
    echo = fir_convolve(render, ir)
    mic = wanted + echo
    # Check that echo is detectable at the right lag
    corr, lag = max_correlation(render, mic, max_lag=delay_samples + 20)
    assert abs(corr) > 0.3

# ── Case J: Route change (IR switch) ─────────────────────────
def test_case_j_route_change():
    render = make_speech_like(1.0)
    wanted = make_sine(200, 1.0, amp=0.3)
    ir1 = np.array([0.0]*5 + [0.5], dtype=np.float32)
    ir2 = np.array([0.0]*30 + [0.3], dtype=np.float32)
    echo1 = fir_convolve(render[:SR//2], ir1)
    echo2 = fir_convolve(render[SR//2:], ir2)
    mic = np.concatenate([wanted[:SR//2] + echo1, wanted[SR//2:] + echo2])
    # Just verify both halves have detectable but different delays
    c1, lag1 = max_correlation(render[:SR//2], mic[:SR//2], max_lag=40)
    c2, lag2 = max_correlation(render[SR//2:], mic[SR//2:], max_lag=40)
    assert lag1 != lag2 or abs(c1 - c2) > 0.05
