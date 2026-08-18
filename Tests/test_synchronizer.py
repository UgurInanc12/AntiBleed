import pytest

class SimpleSynchronizer:
    def __init__(self):
        self.render_q = []
        self.mic_q = []
        self.underruns = 0
    def push_render(self, f): self.render_q.append(f)
    def push_mic(self, f): self.mic_q.append(f)
    def pull(self):
        if not self.render_q or not self.mic_q:
            self.underruns += 1
            return None
        return (self.render_q.pop(0), self.mic_q.pop(0))
    def reset(self):
        self.render_q.clear(); self.mic_q.clear()

def test_pairing():
    s = SimpleSynchronizer()
    s.push_render("r1"); s.push_mic("m1")
    s.push_render("r2"); s.push_mic("m2")
    assert s.pull() == ("r1", "m1")
    assert s.pull() == ("r2", "m2")

def test_underflow():
    s = SimpleSynchronizer()
    s.push_render("r1")
    assert s.pull() is None
    assert s.underruns == 1

def test_stale_drop():
    s = SimpleSynchronizer()
    s.push_render("r1"); s.push_render("r2"); s.push_render("r3")
    s.push_mic("m1")
    # If render is ahead, mic-starved synchronizer underflows until mic catches up
    assert s.pull() == ("r1", "m1")
    assert s.pull() is None  # no mic for r2

def test_reset():
    s = SimpleSynchronizer()
    s.push_render("r1"); s.push_mic("m1")
    s.reset()
    assert s.pull() is None
