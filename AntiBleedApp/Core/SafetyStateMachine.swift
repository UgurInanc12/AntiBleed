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

    /// Called on every state change with (from, to). Rate-limited by nature: never per frame.
    public var onTransition: ((PipelineState, PipelineState) -> Void)?

    private var ramp = CrossfadeRamp()
    private var rampDirectionToProcessed = true

    public init() {}

    public func start() { transition(to: .bypass); ramp.reset() }
    public func stop() { transition(to: .stopped); ramp.reset() }
    public func fail() { transition(to: .error); ramp.reset() }

    public func reset() {
        transition(to: .bypass)
        couplingConfidence = 0
        aecDelayMs = nil
        ramp.reset()
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
            return .rawMic
        }
        couplingConfidence = coupling.score
        aecDelayMs = aecStats.valid && aecStats.delayMs >= 0 ? aecStats.delayMs : (coupling.delayMs >= 0 ? coupling.delayMs : nil)

        // Hard fail-safe: diverging filter while processed audio is exposed.
        if aecStats.divergentFilterFraction > hardDivergence && (state == .active || state == .learning) {
            transition(to: .degraded)
            beginRamp(toProcessed: false)
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
            if !renderActivity.isActive || coupling.score < learningAbortScore {
                transition(to: .bypass); return .rawMic
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
            if !renderActivity.isActive {
                transition(to: .bypass)
                beginRamp(toProcessed: false)
                return rampedOutput(idle: .rawMic)
            }
            if coupling.score < activeExitScore || aecStats.divergentFilterFraction > degradedDivergence {
                transition(to: .degraded)
                beginRamp(toProcessed: false)
                return rampedOutput(idle: .rawMic)
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
