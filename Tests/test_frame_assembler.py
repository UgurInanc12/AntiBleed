import pytest
import numpy as np
from dsp.resampler import Resampler

# Mirrors AntiBleedApp/Audio/FormatConverter logic in Python
FRAME = 480

class FrameAssembler:
    def __init__(self, target_rate=48000):
        self.target_rate = target_rate
        self.pending = []

    def push(self, samples, sample_rate=48000, channels=1):
        # Channel handling
        if channels > 1:
            mono = []
            for i in range(0, len(samples), channels):
                mono.append(sum(samples[i:i+channels]) / channels)
            samples = mono
        # Resample stub
        if abs(sample_rate - self.target_rate) > 1:
            r = Resampler(sample_rate, self.target_rate)
            samples = r.process(np.array(samples, dtype=np.float32)).tolist()
        self.pending.extend(samples)
        frames = []
        while len(self.pending) >= FRAME:
            frames.append(self.pending[:FRAME])
            self.pending = self.pending[FRAME:]
        return frames

def test_variable_input_sizes():
    asm = FrameAssembler()
    for size in [128, 256, 512, 1024, 77]:
        x = [0.1] * size
        frames = asm.push(x)
        for f in frames:
            assert len(f) == FRAME
    # Remainder < FRAME
    assert len(asm.pending) < FRAME

def test_exact_480():
    asm = FrameAssembler()
    frames = asm.push([0.2] * 480)
    assert len(frames) == 1
    assert len(frames[0]) == 480

def test_stereo_downmix():
    asm = FrameAssembler()
    stereo = [0.4, 0.6] * 240  # 480 stereo samples = 240 mono
    frames = asm.push(stereo, channels=2)
    assert len(frames) == 0  # 240 mono < 480
    frames += asm.push([0.5, 0.5] * 240, channels=2)
    assert len(frames) == 1  # now 480 mono

def test_sequence_monotonic():
    asm = FrameAssembler()
    # Feed 3*480 samples in chunks
    for _ in range(3):
        frames = asm.push([0.1] * 500)
    # Total 1500 samples -> 3 frames, 60 remainder
    # Actually push 500 three times: 500->1 frame+20 remainder, 520->1 frame+40, 540->1 frame+60
    # So 3 frames produced
    asm2 = FrameAssembler()
    f1 = asm2.push([0.1]*1000)
    f2 = asm2.push([0.1]*500)
    assert len(f1) + len(f2) == 3
