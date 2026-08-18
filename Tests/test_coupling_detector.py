import pytest
import numpy as np
from dsp.coupling_detector import CouplingDetector

def test_no_coupling():
    det = CouplingDetector()
    render = np.random.randn(480).astype(np.float32)
    mic = np.random.randn(480).astype(np.float32)  # unrelated
    stats = {"delayMs": -1, "delayStddevMs": 99, "divergentFilterFraction": 0.0}
    # Run several windows
    for _ in range(10):
        r = det.update(render, mic, stats)
    assert r["score"] < 0.35

def test_strong_coupling():
    det = CouplingDetector()
    render = np.random.randn(1000).astype(np.float32)
    mic = np.zeros(1000, dtype=np.float32)
    mic[20:] = render[:980] * 0.5  # delayed copy = echo
    # Simulate stable AEC delay matching
    stats = {"delayMs": 0, "delayStddevMs": 1.0, "divergentFilterFraction": 0.0}
    for _ in range(15):
        r = det.update(render[:480], mic[:480], stats)
    # After warmup, score should rise
    assert r["score"] > 0.4

def test_divergence_kills_score():
    det = CouplingDetector()
    render = np.random.randn(480).astype(np.float32)
    mic = render * 0.5
    stats_bad = {"delayMs": 10, "delayStddevMs": 1.0, "divergentFilterFraction": 0.9}
    for _ in range(5):
        r = det.update(render, mic, stats_bad)
    # Divergence suppresses aec_health
    assert r["score"] < 0.7

def test_reset():
    det = CouplingDetector()
    render = np.random.randn(480).astype(np.float32)
    mic = render * 0.5
    stats = {"delayMs": 0, "delayStddevMs": 1.0, "divergentFilterFraction": 0.0}
    for _ in range(5):
        det.update(render, mic, stats)
    det.reset()
    assert det.stable_windows == 0
    assert det.smoothed_score == 0.0
