import pytest
import numpy as np

# Python simulation of AntiBleedDriver/SharedRingBuffer (frame = 480 floats)

FRAME = 480

class SharedRingBuffer:
    def __init__(self, capacity_frames, frame_size=FRAME):
        self.capacity = capacity_frames
        self.frame_size = frame_size
        self.buf = np.zeros(capacity_frames * frame_size, dtype=np.float32)
        self.wpos = 0
        self.rpos = 0
        self.size = 0  # in frames
        self.overruns = 0
        self.underruns = 0

    def push(self, data: np.ndarray, num_frames: int):
        if num_frames > self.capacity:
            data = data[-(self.capacity * self.frame_size):]
            num_frames = self.capacity
        total = num_frames * self.frame_size
        if self.size + num_frames > self.capacity:
            dropped = self.size + num_frames - self.capacity
            self.rpos = (self.rpos + dropped * self.frame_size) % len(self.buf)
            self.size = self.capacity - num_frames
            self.overruns += dropped
        for i in range(total):
            self.buf[(self.wpos + i) % len(self.buf)] = data[i]
        self.wpos = (self.wpos + total) % len(self.buf)
        if self.overruns and self.size + num_frames == self.capacity:
            self.size = self.capacity
        else:
            self.size += num_frames if self.size + num_frames <= self.capacity else 0
            # Correct for non-overflow case
            if self.size > self.capacity:
                self.size = self.capacity
        return 0

    def pop(self, num_frames: int):
        avail = min(self.size, num_frames)
        out = np.zeros(num_frames * self.frame_size, dtype=np.float32)
        for i in range(avail * self.frame_size):
            out[i] = self.buf[(self.rpos + i) % len(self.buf)]
        remain = (num_frames - avail) * self.frame_size
        if remain:
            self.underruns += num_frames - avail
        self.rpos = (self.rpos + avail * self.frame_size) % len(self.buf)
        self.size -= avail
        return out, avail


def test_writer_reader_loopback():
    ring = SharedRingBuffer(10)
    tone = (np.sin(np.linspace(0, 2*np.pi*10, FRAME)) * 0.5).astype(np.float32)
    ring.push(tone, 1)
    out, avail = ring.pop(1)
    assert avail == 1
    assert np.allclose(out, tone, atol=1e-6)

def test_underflow_silence():
    ring = SharedRingBuffer(10)
    out, avail = ring.pop(1)
    assert avail == 0
    assert np.allclose(out, 0.0)
    assert ring.underruns == 1

def test_overrun_drops_oldest():
    ring = SharedRingBuffer(3)
    for i in range(5):
        data = np.full(FRAME, float(i), dtype=np.float32)
        ring.push(data, 1)
    # Capacity 3, pushed 5 -> oldest 2 dropped, kept 2,3,4
    out, avail = ring.pop(3)
    assert avail == 3
    # First frame should be 2.0
    assert out[0] == pytest.approx(2.0)
    assert out[FRAME] == pytest.approx(3.0)
    assert out[2*FRAME] == pytest.approx(4.0)

def test_silence_on_stop_writing():
    ring = SharedRingBuffer(10)
    tone = np.ones(FRAME, dtype=np.float32) * 0.7
    ring.push(tone, 1)
    ring.pop(1)
    # No more pushes, next pop is silence
    out, avail = ring.pop(1)
    assert avail == 0
    assert np.allclose(out, 0.0)

def test_frame_size_invariant():
    ring = SharedRingBuffer(5)
    data = np.random.randn(FRAME).astype(np.float32)
    ring.push(data, 1)
    assert ring.size == 1
    out, _ = ring.pop(1)
    assert len(out) == FRAME
