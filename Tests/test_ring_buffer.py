import pytest
import numpy as np
from dsp.ring_buffer import RingBuffer

def test_push_pop_basic():
    rb = RingBuffer(10)
    assert rb.push([1,2,3]) == 0
    assert rb.available() == 3
    out = rb.pop(3)
    assert out == [1,2,3]
    assert rb.available() == 0

def test_overflow_drops_oldest():
    rb = RingBuffer(5)
    rb.push([1,2,3,4,5])
    dropped = rb.push([6,7])
    assert dropped == 2
    assert rb.overruns == 2
    out = rb.pop(5)
    assert out == [3,4,5,6,7]

def test_underflow_fills_silence():
    rb = RingBuffer(5)
    rb.push([1,2])
    out = rb.pop(5)
    assert out[:2] == [1,2]
    assert out[2:] == [0.0, 0.0, 0.0]
    assert rb.underruns == 3

def test_wrap_around():
    rb = RingBuffer(4)
    rb.push([1,2,3,4])
    rb.pop(2)
    rb.push([5,6])
    out = rb.pop(4)
    assert out == [3,4,5,6]

def test_large_push_truncates():
    rb = RingBuffer(3)
    dropped = rb.push([1,2,3,4,5,6])
    # Keeps last 3
    assert rb.available() == 3
    out = rb.pop(3)
    assert out == [4,5,6]

def test_reset():
    rb = RingBuffer(5)
    rb.push([1,2,3])
    rb.pop(5)  # underrun
    rb.reset()
    assert rb.available() == 0
    assert rb.overruns == 0
    assert rb.underruns == 0

def test_float_frames():
    # Simulate 480-sample frames: capacity is in elements (floats), so need >=960
    rb = RingBuffer(2000)
    frame = [0.5] * 480
    rb.push(frame)
    rb.push(frame)
    assert rb.available() == 960
    out = rb.pop(480)
    assert len(out) == 480
    assert all(v == 0.5 for v in out)

def test_spsc_like_sequence():
    rb = RingBuffer(100)
    for i in range(20):
        rb.push([float(i)])
    out = rb.pop(20)
    assert out == [float(i) for i in range(20)]
