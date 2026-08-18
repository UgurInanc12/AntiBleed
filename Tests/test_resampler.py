import pytest
import numpy as np
from dsp.resampler import Resampler

def test_passthrough_same_rate():
    r = Resampler(48000, 48000)
    x = np.random.randn(1000).astype(np.float32)
    y = r.process(x)
    assert len(y) == len(x)
    assert np.allclose(x, y, atol=1e-6)

def test_441_to_48():
    r = Resampler(44100, 48000)
    # 441 samples at 44.1k ~ 10ms should become ~480 at 48k
    x = np.sin(np.linspace(0, 2*np.pi*5, 441)).astype(np.float32)
    y = r.process(x)
    assert 475 <= len(y) <= 485

def test_48_to_441():
    r = Resampler(48000, 44100)
    x = np.sin(np.linspace(0, 2*np.pi*5, 480)).astype(np.float32)
    y = r.process(x)
    assert 435 <= len(y) <= 445

def test_empty():
    r = Resampler(48000, 48000)
    assert len(r.process(np.array([], dtype=np.float32))) == 0
