import Foundation

/// AEC safety state machine (PLAN 13.2, D-012).
///
/// Decides which signal the virtual microphone exposes based on render activity,
/// acoustic coupling confidence and AEC3 health. The failure mode is always
/// "speaker bleed returns temporarily" and never "user voice destroyed".
///
///   STOPPED -> BYPASS -> PROBING -> LEARNING -> ACTIVE
///                 ^          |          |          |
///                 +----------+----------+---- DEGRADED
///
/// Rules:
///  - Output is raw mic unless the state is ACTIVE (or a crossfade into/out of it).
///  - Any route change drops straight to BYPASS with raw mic.
///  - AEC keeps adapting in every state; only the exposed signal changes.
///  - Every transition between raw and processed is a bounded crossfade.
///
/// Far-end silence is deliberately NOT a reason to leave ACTIVE (D-020).
/// Measured against the real AEC3: while the far end is silent the canceller is
/// transparent (0.0 dB level delta, 0.985 correlation with the raw mic), so
/// dropping to BYPASS protects nothing and only produces an audible transition
/// every time the other side pauses. Coupling evidence decays slowly during
/// silence, so ACTIVE is held through pauses by `activeSilenceGraceFrames` and
/// only the real hazards (no coupling while the far end plays, filter
/// divergence, route change) still force raw mic.
public final class SafetyStateMachine {
    public private(set) var state: PipelineState = .stopped
    public private(set) var couplingConfidence: Float = 0
    public private(set) var aecDelayMs: Int? = nil
    public private(set) var framesInState: Int = 0
    public private(set) var transitionCount: UInt64 = 0

    // Tuning (diagnostics-configurable, PLAN 13.5).
    public var learnEnterScore: Float = 0.6
    public var learnEnterStableWindows: Int = 3
    public var activeEnterScore: Float = 0.7
    public var activeEnterMinFrames: Int = 30        // >= 300 ms in LEARNING
    public var learningAbortScore: Float = 0.3
    public var activeExitScore: Float = 0.35
    public var degradedDivergence: Float = 0.2
    public var hardDivergence: Float = 0.3
    public var degradedRecoverScore: Float = 0.65
    public var degradedTimeoutFrames: Int = 50       // 500 ms
    public var crossfadeFrames: Int = 10              // 100 ms
    /// Consecutive frames of contrary evidence required before ACTIVE or LEARNING
    /// is abandoned (D-022). Measured on a quiet room (speakers -59 dBFS, mic
    /// -84 dBFS): the coupling score swings across the decision thresholds, with
    /// 32% of samples within 0.05 of activeEnter and 17% within 0.05 of
    /// activeExit. Judging a single frame made the badge cycle
    /// probing -> learning -> active continuously. Evidence must persist.
    public var exitConfirmFrames: Int = 200           // 2 s
    /// Minimum time in ACTIVE before coupling may expel it. Prevents an
    /// immediate bounce right after the climb, while divergence (a real fault)
    /// is still allowed to fire at any moment.
    public var activeMinDwellFrames: Int = 100        // 1 s
    /// How long ACTIVE survives a silent far end before falling back to raw
    /// (D-020). 0 means "never fall back on silence alone", which is the
    /// shipped behaviour: with no render to cancel the AEC is transparent
    /// (measured 0.0 dB delta, 0.985 correlation), so a timeout would only
    /// manufacture an audible transition and a re-learning climb. The real
    /// hazards (coupling lost while the far end plays, divergence, route
    /// change) are handled by their own rules and are not time based.
    public var activeSilenceGraceFrames: Int = 0
    /// Same for LEARNING, so a pause mid-learning does not restart the whole
    /// PROBING -> LEARNING climb. Finite here: LEARNING has not yet proven a
    /// coupling path, so it must not linger indefinitely on no evidence.
    public var learningSilenceGraceFrames: Int = 500  // 5 s


    /// Called on every state change with (from, to). Rate-limited by nature: never per frame.
    public var onTransition: ((PipelineState, PipelineState) -> Void)?

    private var ramp = CrossfadeRamp()
    private var rampDirectionToProcessed = true
    /// Consecutive frames with a silent far end. Reset by any render activity.
    private var silentFrames = 0
    /// Consecutive frames of evidence against the current processed state
    /// (D-022). Any frame of good evidence resets it, so only a sustained loss
    /// of coupling leaves ACTIVE or aborts LEARNING.
    private var contraryFrames = 0

    public init() {}

    public func start() { transition(to: .bypass); ramp.reset(); silentFrames = 0; contraryFrames = 0 }
    public func stop() { transition(to: .stopped); ramp.reset(); silentFrames = 0; contraryFrames = 0 }
    public func fail() { transition(to: .error); ramp.reset(); silentFrames = 0; contraryFrames = 0 }

    public func reset() {
        transition(to: .bypass)
        couplingConfidence = 0
        aecDelayMs = nil
        ramp.reset()
        silentFrames = 0
        contraryFrames = 0
    }

    /// Per 10 ms frame. Returns which signal to expose for this frame.
    public func update(renderActivity: RenderActivity,
                       coupling: CouplingResult,
                       aecStats: AECStats,
                       aecAvailable: Bool = true,
                       routeChanged: Bool = false) -> OutputSelection {
        if routeChanged {
            transition(to: .bypass)
            ramp.reset()
            silentFrames = 0
            contraryFrames = 0
            return .rawMic
        }
        couplingConfidence = coupling.score
        aecDelayMs = aecStats.valid && aecStats.delayMs >= 0 ? aecStats.delayMs : (coupling.delayMs >= 0 ? coupling.delayMs : nil)

        if renderActivity.isActive {
            silentFrames = 0
        } else if silentFrames < Int.max {
            // Saturating: with no timeout the counter would otherwise run for the
            // lifetime of the session.
            silentFrames &+= 1
        }

        // Hard fail-safe: diverging filter while processed audio is exposed.
        if aecStats.divergentFilterFraction > hardDivergence && (state == .active || state == .learning) {
            transition(to: .degraded)
            beginRamp(toProcessed: false)
        }

        // The AEC became unavailable (user toggle off, no real engine, or the
        // reference output is no longer the one macOS plays through). Processed
        // audio must not stay exposed: crossfade back to the raw mic (D-020).
        if !aecAvailable && (state == .active || state == .learning || state == .probing) {
            let wasProcessed = state == .active
            transition(to: .bypass)
            if wasProcessed { beginRamp(toProcessed: false) } else { ramp.reset() }
            framesInState += 1
            return wasProcessed ? rampedOutput(idle: .rawMic) : .rawMic
        }

        framesInState += 1

        switch state {
        case .stopped, .error:
            return .silence

        case .bypass:
            if renderActivity.isActive && aecAvailable { transition(to: .probing) }
            return rampedOutput(idle: .rawMic)

        case .probing:
            if !renderActivity.isActive { transition(to: .bypass); return .rawMic }
            if coupling.score > learnEnterScore && coupling.stableWindows >= learnEnterStableWindows {
                transition(to: .learning)
            }
            return .rawMic

        case .learning:
            // A pause in the far end is not evidence against coupling; keep
            // learning through it (D-020) and only give up on a long silence.
            if silentFrames > learningSilenceGraceFrames {
                transition(to: .bypass); return .rawMic
            }
            // Sustained contrary evidence, not a single bad frame (D-022).
            if renderActivity.isActive && coupling.score < learningAbortScore {
                contraryFrames += 1
                if contraryFrames > exitConfirmFrames {
                    transition(to: .bypass); return .rawMic
                }
            } else {
                contraryFrames = 0
            }
            if coupling.score > activeEnterScore
                && aecStats.divergentFilterFraction < 0.1
                && framesInState > activeEnterMinFrames {
                transition(to: .active)
                beginRamp(toProcessed: true)
                return rampedOutput(idle: .aecProcessed)
            }
            return .rawMic

        case .active:
            // Far-end silence keeps ACTIVE: the AEC is transparent with no render
            // to cancel, so switching back to raw would only cause an audible
            // transition (D-020). With activeSilenceGraceFrames == 0 silence
            // alone never releases the state.
            if activeSilenceGraceFrames > 0 && silentFrames > activeSilenceGraceFrames {
                transition(to: .bypass)
                beginRamp(toProcessed: false)
                return rampedOutput(idle: .rawMic)
            }
            // Divergence is a real fault: act on it immediately, at any moment.
            if aecStats.divergentFilterFraction > degradedDivergence {
                contraryFrames = 0
                transition(to: .degraded)
                beginRamp(toProcessed: false)
                return rampedOutput(idle: .rawMic)
            }
            // Coupling is only re-judged while the far end actually plays; during
            // silence the score decays for lack of evidence, not for lack of an
            // echo path. A dip must persist (D-022): near the threshold the score
            // swings frame to frame and single-frame judgement made the state
            // oscillate audibly.
            if renderActivity.isActive && coupling.score < activeExitScore {
                contraryFrames += 1
                if contraryFrames > exitConfirmFrames && framesInState > activeMinDwellFrames {
                    transition(to: .degraded)
                    beginRamp(toProcessed: false)
                    return rampedOutput(idle: .rawMic)
                }
            } else {
                contraryFrames = 0
            }
            return rampedOutput(idle: .aecProcessed)

        case .degraded:
            if framesInState > degradedTimeoutFrames { transition(to: .bypass); return .rawMic }
            if coupling.score > degradedRecoverScore && aecStats.divergentFilterFraction < 0.05 {
                transition(to: .learning)
            }
            return rampedOutput(idle: .rawMic)
        }
    }


    // MARK: - Internals

    private func transition(to new: PipelineState) {
        guard new != state else { return }
        let old = state
        state = new
        framesInState = 0
        transitionCount += 1
        onTransition?(old, new)
    }

    private func beginRamp(toProcessed: Bool) {
        rampDirectionToProcessed = toProcessed
        ramp.start(frames: crossfadeFrames)
    }

    /// While a ramp is active, expose a crossfade whose progress moves toward the
    /// idle target (1 = processed, 0 = raw). Otherwise expose `idle`.
    private func rampedOutput(idle: OutputSelection) -> OutputSelection {
        guard ramp.isActive else { return idle }
        let p = ramp.progress
        ramp.advance()
        let progress = rampDirectionToProcessed ? p : (1 - p)
        return .crossfade(progress: progress)
    }
}
