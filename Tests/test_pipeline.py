import pytest
import numpy as np
from dsp.signal_metrics import rms

FRAME = 480

class FakePipeline:
    """Simulates AntiBleedPipeline wiring without real Core Audio."""
    def __init__(self):
        self.render_queue = []
        self.mic_queue = []
        self.aec_enabled = True

    def push_render(self, frame): self.render_queue.append(frame)
    def push_mic(self, frame): self.mic_queue.append(frame)

    def process_one(self):
        if not self.render_queue or not self.mic_queue:
            return None  # underflow -> skip, don't feed AEC stale data
        render = self.render_queue.pop(0)
        mic = self.mic_queue.pop(0)
        if not self.aec_enabled:
            return mic
        # Passthrough stub (Phase 5 real would call AECBridge)
        # For bypass test: if render is silence, return raw mic
        if rms(np.array(render)) < 1e-6:
            return mic
        # Otherwise pretend AEC would clean: return mic as-is for stub
        return mic


def test_underflow_no_stale():
    p = FakePipeline()
    p.push_render([0.1]*FRAME)
    assert p.process_one() is None  # no mic -> underflow, no stale

def test_bypass_when_aec_disabled():
    p = FakePipeline()
    p.aec_enabled = False
    p.push_render([0.5]*FRAME)
    p.push_mic([0.3]*FRAME)
    out = p.process_one()
    assert out == [0.3]*FRAME

def test_silence_gate():
    p = FakePipeline()
    p.push_render([0.0]*FRAME)  # silence
    p.push_mic([0.4]*FRAME)
    out = p.process_one()
    assert out == [0.4]*FRAME  # bypass to raw

def test_ordering_render_before_capture():
    p = FakePipeline()
    # Push in correct order: render then mic
    for _ in range(5):
        p.push_render([0.2]*FRAME)
        p.push_mic([0.3]*FRAME)
    for _ in range(5):
        assert p.process_one() is not None
    assert p.process_one() is None  # queues drained
