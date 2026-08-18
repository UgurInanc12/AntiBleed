import pytest
import numpy as np
from dsp.crossfade import crossfade, crossfade_equal_power, CrossfadeState

def test_crossfade_linear():
    a = np.ones(480, dtype=np.float32)
    b = np.zeros(480, dtype=np.float32)
    out = crossfade(a, b, 0.0)
    assert np.allclose(out, 1.0)
    out = crossfade(a, b, 1.0)
    assert np.allclose(out, 0.0)
    out = crossfade(a, b, 0.5)
    assert np.allclose(out, 0.5)

def test_crossfade_no_click():
    # Splice two different signals with 100ms crossfade (10 frames)
    a = np.ones(480) * 0.8
    b = np.ones(480) * -0.8
    # At 0.5, output should be 0 (midpoint)
    out = crossfade(a, b, 0.5)
    assert np.allclose(out, 0.0, atol=1e-6)

def test_crossfade_state():
    s = CrossfadeState()
    s.start(10)
    assert s.active
    for i in range(10):
        p = s.progress()
        assert 0 <= p <= 1
        s.advance()
    assert not s.active
    assert s.progress() == pytest.approx(1.0)

def test_equal_power():
    a = np.ones(100) * 0.7
    b = np.ones(100) * 0.7
    out = crossfade_equal_power(a, b, 0.5)
    # Equal power: each at -3dB, sum ~ 0.99
    assert abs(float(out[0]) - 0.9899) < 0.01

def test_crossfade_energy_preservation():
    # Linear crossfade of same signal should preserve level
    a = np.random.randn(480).astype(np.float32)
    b = a.copy()
    out = crossfade(a, b, 0.3)
    assert np.allclose(out, a, atol=1e-6)
