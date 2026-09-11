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
        self.silent_frames = 0
        # D-022: sustained contrary evidence, not a single frame.
        self.contrary_frames = 0
        self.exit_confirm_frames = 200
        self.active_min_dwell_frames = 100
        # D-020: far-end silence never releases ACTIVE (0 = no timeout).
        self.active_silence_grace_frames = 0
        self.learning_silence_grace_frames = 500

    def reset(self):
        self.state = "bypass"
        self.frames_in_state = 0
        self.silent_frames = 0

    def update(self, render_activity, coupling, aec_stats, route_changed=False, aec_available=True):
        if route_changed:
            self.state = "bypass"
            self.frames_in_state = 0
            self.silent_frames = 0
            self.contrary_frames = 0
            return "rawMic"
        self.coupling_confidence = coupling.score
        if render_activity.is_active:
            self.silent_frames = 0
        else:
            self.silent_frames += 1
        if aec_stats.divergentFilterFraction > 0.3 and self.state in ("active", "learning"):
            self.state = "degraded"
            self.frames_in_state = 0
        # D-020: no usable AEC (toggle off, or the reference output is not the
        # macOS output) -> raw mic, never silence.
        if not aec_available and self.state in ("active", "learning", "probing"):
            was_processed = self.state == "active"
            self.state = "bypass"
            self.frames_in_state = 0
            return "crossfade" if was_processed else "rawMic"
        self.frames_in_state += 1

        if self.state == "stopped":
            return "silence"
        elif self.state == "error":
            return "silence"
        elif self.state == "bypass":
            if not render_activity.is_active or not aec_available:
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
            if self.silent_frames > self.learning_silence_grace_frames:
                self.state = "bypass"
                return "rawMic"
            # D-022: sustained contrary evidence, not a single frame.
            if render_activity.is_active and coupling.score < 0.3:
                self.contrary_frames += 1
                if self.contrary_frames > self.exit_confirm_frames:
                    self.state = "bypass"
                    return "rawMic"
            else:
                self.contrary_frames = 0
            if coupling.score > 0.7 and aec_stats.divergentFilterFraction < 0.1 and self.frames_in_state > 30:
                self.state = "active"
                self.frames_in_state = 0
                return "crossfade"
            return "rawMic"
        elif self.state == "active":
            if self.active_silence_grace_frames > 0 and self.silent_frames > self.active_silence_grace_frames:
                self.state = "bypass"
                return "crossfade"
            # Divergence is a real fault: immediate, at any moment.
            if aec_stats.divergentFilterFraction > 0.2:
                self.contrary_frames = 0
                self.state = "degraded"
                self.frames_in_state = 0
                return "crossfade"
            # A coupling dip must persist (D-022).
            if render_activity.is_active and coupling.score < 0.35:
                self.contrary_frames += 1
                if (self.contrary_frames > self.exit_confirm_frames
                        and self.frames_in_state > self.active_min_dwell_frames):
                    self.state = "degraded"
                    self.frames_in_state = 0
                    return "crossfade"
            else:
                self.contrary_frames = 0
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


def test_active_survives_far_end_silence():
    """D-020: a pause in the far end must not release ACTIVE. With no render to
    cancel the AEC is transparent (measured: 0.0 dB delta, 0.985 correlation),
    so falling back to raw would only add an audible transition per pause."""
    sm = SafetyStateMachine()
    sm.state = "active"
    for _ in range(60000):  # 10 minutes of silence, coupling evidence fully decayed
        out = sm.update(RenderActivity(False), CouplingResult(score=0.0), AECStats())
        assert sm.state == "active"
        assert out == "aecProcessed"


def test_active_silence_timeout_is_opt_in():
    """The timeout is off by default (0) and only fires when configured."""
    assert SafetyStateMachine().active_silence_grace_frames == 0
    sm = SafetyStateMachine()
    sm.state = "active"
    sm.active_silence_grace_frames = 100
    for _ in range(150):
        sm.update(RenderActivity(False), CouplingResult(score=0.0), AECStats())
    assert sm.state == "bypass"


def test_active_leaves_when_coupling_lost_while_far_end_plays():
    """The real hazard Bypass exists for: headphones plugged in mid-call.

    D-022: the loss must be sustained. A single bad frame no longer ejects
    ACTIVE, because near the threshold the score swings frame to frame and
    single-frame judgement made the state oscillate audibly.
    """
    sm = SafetyStateMachine()
    sm.state = "active"
    sm.frames_in_state = sm.active_min_dwell_frames + 1

    # One bad frame is not enough.
    sm.update(RenderActivity(True), CouplingResult(score=0.05), AECStats())
    assert sm.state == "active"

    # Sustained loss is.
    for _ in range(sm.exit_confirm_frames + 1):
        sm.update(RenderActivity(True), CouplingResult(score=0.05), AECStats())
    assert sm.state == "degraded"


def test_brief_coupling_dip_does_not_leave_active():
    """D-022: the flapping the user reported. A dip shorter than the confirm
    window must not cost a transition."""
    sm = SafetyStateMachine()
    sm.state = "active"
    sm.frames_in_state = sm.active_min_dwell_frames + 1
    for _ in range(30):  # 20 dips of 10 frames, always interrupted by good evidence
        for _ in range(10):
            sm.update(RenderActivity(True), CouplingResult(score=0.05), AECStats())
        sm.update(RenderActivity(True), CouplingResult(score=0.9), AECStats())
    assert sm.state == "active"


def test_divergence_during_silence_still_leaves_active():
    sm = SafetyStateMachine()
    sm.state = "active"
    sm.update(RenderActivity(False), CouplingResult(score=0.9), AECStats(div_frac=0.5))
    assert sm.state == "degraded"


def test_learning_survives_short_pause():
    sm = SafetyStateMachine()
    sm.state = "learning"
    for _ in range(100):  # 1 s pause mid-learning
        sm.update(RenderActivity(False), CouplingResult(score=0.0), AECStats())
    assert sm.state == "learning"


def test_losing_aec_availability_falls_back_to_raw_never_silence():
    """D-020 headphones case: the reference output is no longer the macOS output.
    Processing stops but the microphone must keep flowing."""
    sm = SafetyStateMachine()
    sm.state = "active"
    outs = []
    for _ in range(200):
        outs.append(sm.update(RenderActivity(True), CouplingResult(score=0.9, stable_windows=10),
                              AECStats(), aec_available=False))
        assert sm.state != "active"
    assert "silence" not in outs, "the virtual mic must never go silent on a route change"
    assert sm.state == "bypass"
    assert outs[-1] == "rawMic"


def test_unavailable_aec_never_enters_probing():
    sm = SafetyStateMachine()
    sm.state = "bypass"
    for _ in range(500):
        out = sm.update(RenderActivity(True), CouplingResult(score=0.95, stable_windows=10),
                        AECStats(), aec_available=False)
        assert out == "rawMic"
        assert sm.state == "bypass"
