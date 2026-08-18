import pytest
import numpy as np
import math
from dsp.signal_metrics import rms, peak, rms_db, normalized_correlation, max_correlation, echo_attenuation_db

def test_rms_silence():
    assert rms(np.zeros(100)) == pytest.approx(0.0, abs=1e-9)

def test_rms_sine():
    # Full-scale sine RMS = 1/sqrt(2) ~ 0.707, -3.01 dB
    t = np.linspace(0, 2*math.pi, 480, endpoint=False)
    s = np.sin(t).astype(np.float32)
    assert rms(s) == pytest.approx(0.7071, abs=0.01)
    assert rms_db(s) == pytest.approx(-3.01, abs=0.2)

def test_rms_db_silence():
    assert rms_db(np.zeros(100)) == float('-inf')

def test_peak():
    assert peak(np.array([0.1, -0.9, 0.5])) == pytest.approx(0.9)

def test_correlation_identical():
    a = np.random.randn(1000).astype(np.float32)
    assert normalized_correlation(a, a, 0) == pytest.approx(1.0, abs=1e-5)

def test_correlation_delayed():
    a = np.random.randn(1000).astype(np.float32)
    b = np.zeros(1000, dtype=np.float32)
    b[20:] = a[:980]
    # a correlates with b at lag 20
    assert normalized_correlation(a, b, 0) < 0.5
    assert normalized_correlation(a, b, 20) == pytest.approx(1.0, abs=0.01)

def test_max_correlation():
    a = np.random.randn(1000).astype(np.float32)
    b = np.zeros(1000, dtype=np.float32)
    b[15:] = a[:985]
    corr, lag = max_correlation(a, b, max_lag=30)
    assert corr == pytest.approx(1.0, abs=0.05)
    assert lag == 15

def test_attenuation():
    mic = np.ones(480) * 0.5
    out = np.ones(480) * 0.05
    assert echo_attenuation_db(mic, out) == pytest.approx(20.0, abs=0.1)

def test_attenuation_silence_out():
    mic = np.ones(100) * 0.5
    out = np.zeros(100)
    assert echo_attenuation_db(mic, out) == pytest.approx(60.0)
