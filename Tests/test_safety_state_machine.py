import pytest

# Python mirror of SafetyStateMachine.swift logic

class RenderActivity:
    def __init__(self, is_active, rms_db=-20):
        self.is_active = is_active
        self.rms_db = rms_db

class CouplingResult:
    def __init__(self, score=0, stable_windows=0, delay_ms=-1, correlation=0):
        self.score = score
        self.stable_windows = stable_windows
        self.delay_ms = delay_ms
        self.correlation = correlation

class AECStats:
    def __init__(self, delay_ms=-1, div_frac=0.0):
        self.delay_ms = delay_ms
        self.divergentFilterFraction = div_frac

class SafetyStateMachine:
    def __init__(self):
        self.state = "stopped"
        self.frames_in_state = 0
        self.coupling_confidence = 0.0

    def reset(self):
        self.state = "bypass"
        self.frames_in_state = 0

    def update(self, render_activity, coupling, aec_stats, route_changed=False):
        if route_changed:
            self.state = "bypass"
            self.frames_in_state = 0
            return "rawMic"
        self.coupling_confidence = coupling.score
        if aec_stats.divergentFilterFraction > 0.3 and self.state in ("active", "learning"):
            self.state = "degraded"
            self.frames_in_state = 0
        self.frames_in_state += 1

        if self.state == "stopped":
            return "silence"
        elif self.state == "error":
            return "silence"
        elif self.state == "bypass":
            if not render_activity.is_active:
                return "rawMic"
            self.state = "probing"
            self.frames_in_state = 0
            return "rawMic"
        elif self.state == "probing":
            if not render_activity.is_active:
                self.state = "bypass"
                return "rawMic"
            if coupling.score > 0.6 and coupling.stable_windows >= 3:
                self.state = "learning"
                self.frames_in_state = 0
            return "rawMic"
        elif self.state == "learning":
            if not render_activity.is_active or coupling.score < 0.3:
                self.state = "bypass"
                return "rawMic"
            if coupling.score > 0.7 and aec_stats.divergentFilterFraction < 0.1 and self.frames_in_state > 30:
                self.state = "active"
                self.frames_in_state = 0
                return "crossfade"
            return "rawMic"
        elif self.state == "active":
            if not render_activity.is_active:
                self.state = "bypass"
                return "crossfade"
            if coupling.score < 0.35 or aec_stats.divergentFilterFraction > 0.2:
                self.state = "degraded"
                self.frames_in_state = 0
                return "crossfade"
            return "aecProcessed"
        elif self.state == "degraded":
            if self.frames_in_state > 50:
                self.state = "bypass"
                return "rawMic"
            if coupling.score > 0.65 and aec_stats.divergentFilterFraction < 0.05:
                self.state = "learning"
                self.frames_in_state = 0
            return "rawMic"
        return "rawMic"


def test_bypass_when_render_silent():
    sm = SafetyStateMachine()
    sm.state = "bypass"
    out = sm.update(RenderActivity(False), CouplingResult(score=0.9, stable_windows=10), AECStats())
    assert out == "rawMic"
    assert sm.state == "bypass"

def test_probing_to_learning():
    sm = SafetyStateMachine()
    sm.state = "probing"
    for _ in range(5):
        out = sm.update(RenderActivity(True), CouplingResult(score=0.7, stable_windows=5), AECStats(div_frac=0.0))
    assert sm.state == "learning"

def test_learning_to_active():
    sm = SafetyStateMachine()
    sm.state = "learning"
    sm.frames_in_state = 31
    out = sm.update(RenderActivity(True), CouplingResult(score=0.8, stable_windows=8), AECStats(div_frac=0.0))
    assert sm.state == "active"
    assert out == "crossfade"

def test_active_to_degraded_on_divergence():
    sm = SafetyStateMachine()
    sm.state = "active"
    out = sm.update(RenderActivity(True), CouplingResult(score=0.8), AECStats(div_frac=0.5))
    assert sm.state == "degraded"

def test_route_change_immediate_bypass():
    sm = SafetyStateMachine()
    sm.state = "active"
    out = sm.update(RenderActivity(True), CouplingResult(score=0.9, stable_windows=10), AECStats(), route_changed=True)
    assert sm.state == "bypass"
    assert out == "rawMic"

def test_headphones_no_coupling_stays_bypass():
    sm = SafetyStateMachine()
    sm.state = "bypass"
    # Render active but no coupling (headphones case)
    for _ in range(10):
        out = sm.update(RenderActivity(True), CouplingResult(score=0.1, stable_windows=0), AECStats())
    # Should never reach active
    assert sm.state in ("bypass", "probing")
    assert out == "rawMic"

def test_degraded_to_bypass_timeout():
    sm = SafetyStateMachine()
    sm.state = "degraded"
    sm.frames_in_state = 51
    out = sm.update(RenderActivity(True), CouplingResult(score=0.1), AECStats())
    assert sm.state == "bypass"

def test_output_never_inverted_render():
    # The state machine only returns rawMic/aecProcessed/crossfade/silence
    # Never rawRender or mic-minus-render
    sm = SafetyStateMachine()
    sm.state = "bypass"
    valid = {"rawMic", "aecProcessed", "crossfade", "silence"}
    for _ in range(20):
        out = sm.update(RenderActivity(True), CouplingResult(score=0.5), AECStats())
        assert out in valid
