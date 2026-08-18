import Foundation
import Combine

/// AEC safety state machine (PLAN 13.2).
/// Decides output selection based on render activity, coupling, and AEC health.

enum AECState: String, Equatable {
    case stopped
    case bypass
    case probing
    case learning
    case active
    case degraded
    case error
}

enum OutputSelection: Equatable {
    case rawMic
    case aecProcessed
    case crossfade(progress: Float) // 0 = raw, 1 = processed
    case silence
}

struct RenderActivity {
    var isActive: Bool
    var rmsDb: Float
    var hangoverMs: Int
}

struct CouplingResult {
    var score: Float // 0..1
    var delayMs: Int
    var correlation: Float
    var stableWindows: Int
}

struct AECStats {
    var delayMs: Int = -1
    var delayMedianMs: Int = -1
    var delayStddevMs: Float = -1
    var echoReturnLoss: Float = 0
    var echoReturnLossEnhancement: Float = 0
    var divergentFilterFraction: Float = 0
    var residualEchoLikelihood: Float = 0
}

final class SafetyStateMachine: ObservableObject {
    @Published var state: AECState = .stopped
    @Published var couplingConfidence: Float = 0
    @Published var aecDelayMs: Int?

    // Tuning (diagnostics-configurable, not hard-coded)
    var enterHysteresisMs: Int = 500
    var exitHysteresisMs: Int = 1000
    var crossfadeFrames: Int = 10 // 100 ms

    private var framesInState: Int = 0
    private var candidateScore: Float = 0
    private var crossfadeProgress: Float = 0

    func reset() {
        state = .bypass
        framesInState = 0
        couplingConfidence = 0
        aecDelayMs = nil
    }

    /// Called per 10 ms frame. Returns which signal to expose.
    func update(renderActivity: RenderActivity,
                coupling: CouplingResult,
                aecStats: AECStats,
                routeChanged: Bool) -> OutputSelection {
        if routeChanged {
            state = .bypass
            framesInState = 0
            return .rawMic
        }

        couplingConfidence = coupling.score
        aecDelayMs = aecStats.delayMs >= 0 ? aecStats.delayMs : coupling.delayMs

        // Divergence fail-safe
        if aecStats.divergentFilterFraction > 0.3 {
            if state == .active || state == .learning {
                state = .degraded
                framesInState = 0
            }
        }

        framesInState += 1

        switch state {
        case .stopped:
            return .silence
        case .error:
            return .silence
        case .bypass:
            if !renderActivity.isActive { return .rawMic }
            // Render active, start probing
            state = .probing
            framesInState = 0
            return .rawMic
        case .probing:
            if !renderActivity.isActive {
                state = .bypass
                return .rawMic
            }
            if coupling.score > 0.6 && coupling.stableWindows >= 3 {
                state = .learning
                framesInState = 0
            }
            return .rawMic
        case .learning:
            if !renderActivity.isActive || coupling.score < 0.3 {
                state = .bypass
                return .rawMic
            }
            if coupling.score > 0.7 && aecStats.divergentFilterFraction < 0.1 && framesInState > 30 {
                state = .active
                framesInState = 0
                return .crossfade(progress: 0)
            }
            return .rawMic
        case .active:
            if !renderActivity.isActive { state = .bypass; return .crossfade(progress: 0.8) }
            if coupling.score < 0.35 || aecStats.divergentFilterFraction > 0.2 {
                state = .degraded
                framesInState = 0
                return .crossfade(progress: 0.5)
            }
            return .aecProcessed
        case .degraded:
            if framesInState > 50 { // ~500 ms
                state = .bypass
                return .rawMic
            }
            if coupling.score > 0.65 && aecStats.divergentFilterFraction < 0.05 {
                state = .learning
                framesInState = 0
            }
            return .rawMic
        }
    }
}
