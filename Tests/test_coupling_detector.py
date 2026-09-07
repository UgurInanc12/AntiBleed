import numpy as np
from dsp.coupling_detector import CouplingDetector

FRAME = 480


def _run(det, render, mic, stats, frames):
    """Feed `frames` consecutive 10 ms frames and evaluate every 10 (as the engine does)."""
    r = None
    for i in range(frames):
        s = slice(i * FRAME, (i + 1) * FRAME)
        det.push(render[s], mic[s])
        if i % 10 == 0:
            r = det.evaluate(stats)
    return r


def test_no_coupling():
    rng = np.random.default_rng(0)
    det = CouplingDetector()
    n = FRAME * 200
    render = rng.standard_normal(n).astype(np.float32)
    mic = rng.standard_normal(n).astype(np.float32)  # unrelated
    r = _run(det, render, mic, {"valid": True, "delayMs": 40, "erleDb": 0.2, "divergentFilterFraction": 0.0}, 200)
    assert r["score"] < 0.2
    assert r["stable_windows"] == 0


def test_strong_coupling_with_delay():
    rng = np.random.default_rng(1)
    det = CouplingDetector()
    n = FRAME * 200
    render = rng.standard_normal(n).astype(np.float32)
    delay = int(0.045 * 48000)
    mic = np.zeros(n, dtype=np.float32)
    mic[delay:] = render[:-delay] * 0.5  # 45 ms echo
    stats = {"valid": True, "delayMs": 45, "erleDb": 20.0, "divergentFilterFraction": 0.0}
    r = _run(det, render, mic, stats, 200)
    assert r["score"] > 0.8
    assert r["stable_windows"] >= 5
    assert abs(r["correlation"]) > 0.9
    assert abs(r["peak_lag_ms"] - 45) <= 2


def test_coupling_found_without_aec_hint():
    """Before AEC3 has a delay estimate the full 0-250 ms range is scanned."""
    rng = np.random.default_rng(2)
    det = CouplingDetector()
    n = FRAME * 200
    render = rng.standard_normal(n).astype(np.float32)
    delay = int(0.120 * 48000)
    mic = np.zeros(n, dtype=np.float32)
    mic[delay:] = render[:-delay] * 0.4
    r = _run(det, render, mic, {"valid": False, "delayMs": -1, "erleDb": 0.0, "divergentFilterFraction": 0.0}, 200)
    assert abs(r["correlation"]) > 0.85
    assert abs(r["peak_lag_ms"] - 120) <= 3
    assert r["score"] > 0.5  # correlation + stability alone (no ERLE evidence yet)


def test_divergence_halves_score():
    rng = np.random.default_rng(3)
    n = FRAME * 200
    render = rng.standard_normal(n).astype(np.float32)
    mic = render * 0.5
    good = _run(CouplingDetector(), render, mic, {"valid": True, "delayMs": 0, "erleDb": 20.0, "divergentFilterFraction": 0.0}, 200)
    bad = _run(CouplingDetector(), render, mic, {"valid": True, "delayMs": 0, "erleDb": 20.0, "divergentFilterFraction": 0.9}, 200)
    assert bad["score"] < 0.6 * good["score"]


def test_silent_render_decays():
    det = CouplingDetector()
    det.smoothed_score = 1.0
    n = FRAME * 200
    r = _run(det, np.zeros(n, dtype=np.float32), np.random.default_rng(4).standard_normal(n).astype(np.float32),
             {"valid": True, "delayMs": 0, "erleDb": 0.0, "divergentFilterFraction": 0.0}, 200)
    assert r["score"] < 0.1


def test_reset():
    rng = np.random.default_rng(5)
    det = CouplingDetector()
    n = FRAME * 50
    render = rng.standard_normal(n).astype(np.float32)
    _run(det, render, render * 0.5, {"valid": True, "delayMs": 0, "erleDb": 20.0, "divergentFilterFraction": 0.0}, 50)
    det.reset()
    assert det.stable_windows == 0
    assert det.smoothed_score == 0.0
    assert len(det.render_hist) == 0
