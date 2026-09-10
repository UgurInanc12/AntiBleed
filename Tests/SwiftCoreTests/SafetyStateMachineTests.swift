import XCTest
@testable import AntiBleedCore

final class SafetyStateMachineTests: XCTestCase {
    private func stats(div: Float = 0, delay: Int = 40) -> AECStats {
        AECStats(delayMs: delay, delayStddevMs: 1, divergentFilterFraction: div, valid: true)
    }

    func testStoppedIsSilence() {
        let sm = SafetyStateMachine()
        XCTAssertEqual(sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 1, stableWindows: 9), aecStats: stats()), .silence)
    }

    func testBypassWhenRenderSilent() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<50 {
            let out = sm.update(renderActivity: RenderActivity(isActive: false), coupling: CouplingResult(score: 0.9, stableWindows: 10), aecStats: stats())
            XCTAssertEqual(out, .rawMic)
            XCTAssertEqual(sm.state, .bypass)
        }
    }

    /// D-020: a pause in the far end must NOT drop ACTIVE. With no render to
    /// cancel the AEC is transparent, so leaving ACTIVE only produces an audible
    /// transition on every conversational pause. There is no timeout at all.
    func testActiveSurvivesFarEndSilence() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        // 10 minutes of silence with the coupling score decayed to nothing.
        for _ in 0..<60_000 {
            let out = sm.update(renderActivity: RenderActivity(isActive: false), coupling: CouplingResult(score: 0, stableWindows: 0), aecStats: stats())
            XCTAssertEqual(sm.state, .active)
            XCTAssertEqual(out, .aecProcessed)
        }
        // Far end resumes: still ACTIVE, no transition was spent.
        XCTAssertEqual(sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()), .aecProcessed)
        // stopped->bypass, bypass->probing, probing->learning, learning->active.
        // The whole silent stretch added none of its own.
        XCTAssertEqual(sm.transitionCount, 4)
    }

    /// The silence timeout is opt-in: 0 by default, honoured when configured.
    func testActiveSilenceTimeoutIsOptIn() {
        XCTAssertEqual(SafetyStateMachine().activeSilenceGraceFrames, 0)
        let sm = SafetyStateMachine(); sm.start()
        sm.activeSilenceGraceFrames = 100
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        for _ in 0..<150 { _ = sm.update(renderActivity: RenderActivity(isActive: false), coupling: CouplingResult(score: 0), aecStats: stats()) }
        XCTAssertEqual(sm.state, .bypass)
    }

    /// The hazard that Bypass really exists for still works: far end playing
    /// while coupling collapses (user plugged in headphones) leaves ACTIVE.
    func testActiveLeavesWhenCouplingLostWhileFarEndPlays() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.05, stableWindows: 0), aecStats: stats())
        XCTAssertEqual(sm.state, .degraded)
    }

    /// Divergence must still fail safe even while the far end is silent.
    func testDivergenceDuringSilenceStillLeavesActive() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        _ = sm.update(renderActivity: RenderActivity(isActive: false), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats(div: 0.5))
        XCTAssertEqual(sm.state, .degraded)
    }

    /// D-020: losing the reference output (user switched to headphones) must drop
    /// ACTIVE and expose the raw mic. It must never expose silence: the virtual
    /// microphone has to keep carrying the user's voice mid-call.
    func testLosingAECAvailabilityFallsBackToRawNotSilence() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)

        var sawSilence = false
        var out: OutputSelection = .silence
        for _ in 0..<200 {
            out = sm.update(renderActivity: RenderActivity(isActive: true),
                            coupling: CouplingResult(score: 0.9, stableWindows: 10),
                            aecStats: stats(), aecAvailable: false)
            if out == .silence { sawSilence = true }
            XCTAssertNotEqual(sm.state, .active, "must not process without a usable AEC")
        }
        XCTAssertFalse(sawSilence, "the virtual mic must never go silent on a route change")
        XCTAssertEqual(sm.state, .bypass)
        XCTAssertEqual(out, .rawMic)

        // Reference output restored: the FSM is free to climb back to ACTIVE.
        for _ in 0..<200 {
            _ = sm.update(renderActivity: RenderActivity(isActive: true),
                          coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats())
        }
        XCTAssertEqual(sm.state, .active)
    }

    /// The fallback is a crossfade, not a hard cut, so the switch is not a click.
    func testLosingAECAvailabilityCrossfadesOutOfProcessed() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        var progresses: [Float] = []
        for _ in 0..<sm.crossfadeFrames {
            let out = sm.update(renderActivity: RenderActivity(isActive: true),
                                coupling: CouplingResult(score: 0.9, stableWindows: 10),
                                aecStats: stats(), aecAvailable: false)
            if case .crossfade(let p) = out { progresses.append(p) }
        }
        XCTAssertEqual(progresses.count, sm.crossfadeFrames)
        // Fading towards raw: progress (share of processed) decreases.
        XCTAssertEqual(progresses, progresses.sorted(by: >))
    }

    /// A disabled AEC must not even start probing.
    func testUnavailableAECNeverEntersProbing() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<500 {
            let out = sm.update(renderActivity: RenderActivity(isActive: true),
                                coupling: CouplingResult(score: 0.95, stableWindows: 10),
                                aecStats: stats(), aecAvailable: false)
            XCTAssertEqual(out, .rawMic)
            XCTAssertEqual(sm.state, .bypass)
        }
    }

    func testFullPathToActiveWithCrossfade() {
        let sm = SafetyStateMachine(); sm.start()
        var outputs: [OutputSelection] = []
        for _ in 0..<80 {
            outputs.append(sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()))
        }
        XCTAssertEqual(sm.state, .active)
        // Must have passed a crossfade whose progress increases to processed.
        let progresses: [Float] = outputs.compactMap { if case .crossfade(let p) = $0 { return p } else { return nil } }
        XCTAssertEqual(progresses.count, sm.crossfadeFrames)
        XCTAssertEqual(progresses, progresses.sorted())
        XCTAssertEqual(outputs.last, .aecProcessed)
        // Before active, everything was raw.
        let firstXfade = outputs.firstIndex { if case .crossfade = $0 { return true } else { return false } }!
        XCTAssertTrue(outputs[..<firstXfade].allSatisfy { $0 == .rawMic })
    }

    func testHeadphonesNeverActivate() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<500 {
            let out = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.15, stableWindows: 0), aecStats: stats())
            XCTAssertEqual(out, .rawMic)
            XCTAssertTrue(sm.state == .bypass || sm.state == .probing)
        }
    }

    func testActiveToDegradedOnDivergenceThenRecoversToBypass() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats(div: 0.5))
        XCTAssertEqual(sm.state, .degraded)
        var out: OutputSelection = .silence
        var sawBypass = false
        for _ in 0..<60 {
            out = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.1), aecStats: stats(div: 0.5))
            if sm.state == .bypass { sawBypass = true }
            XCTAssertNotEqual(sm.state, .active)
        }
        XCTAssertTrue(sawBypass, "degraded must time out into bypass")
        // Render still active and no coupling: bypass immediately re-enters probing, output stays raw.
        XCTAssertTrue(sm.state == .bypass || sm.state == .probing)
        XCTAssertEqual(out, .rawMic)
    }

    func testRouteChangeIsImmediateBypass() {
        let sm = SafetyStateMachine(); sm.start()
        for _ in 0..<80 { _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.85, stableWindows: 8), aecStats: stats()) }
        XCTAssertEqual(sm.state, .active)
        let out = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(score: 0.9, stableWindows: 10), aecStats: stats(), routeChanged: true)
        XCTAssertEqual(out, .rawMic)
        XCTAssertEqual(sm.state, .bypass)
    }

    func testOnlyLegalOutputs() {
        let sm = SafetyStateMachine(); sm.start()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let out = sm.update(renderActivity: RenderActivity(isActive: Bool.random(using: &rng)),
                                coupling: CouplingResult(score: Float.random(in: 0...1, using: &rng), stableWindows: Int.random(in: 0...10, using: &rng)),
                                aecStats: stats(div: Float.random(in: 0...0.5, using: &rng)))
            switch out {
            case .rawMic, .aecProcessed, .silence: break
            case .crossfade(let p): XCTAssertTrue(p >= 0 && p <= 1)
            }
        }
    }

    func testTransitionCallbackFires() {
        let sm = SafetyStateMachine()
        var log: [(PipelineState, PipelineState)] = []
        sm.onTransition = { log.append(($0, $1)) }
        sm.start()
        _ = sm.update(renderActivity: RenderActivity(isActive: true), coupling: CouplingResult(), aecStats: stats())
        XCTAssertEqual(log.map { $0.1 }, [.bypass, .probing])
    }
}

final class CouplingDetectorTests: XCTestCase {
    private func run(_ d: CouplingDetector, render: [Float], mic: [Float], aecStats stats: AECStats, frames: Int) -> CouplingResult {
        var r = CouplingResult()
        for i in 0..<frames {
            let s = (i * 480)..<((i + 1) * 480)
            d.push(render: Array(render[s]), mic: Array(mic[s]))
            if i % 10 == 0 { r = d.evaluate(aecStats: stats) }
        }
        return r
    }

    func testSilentRenderScoresZero() {
        let d = CouplingDetector()
        let n = 480 * 100
        let r = run(d, render: [Float](repeating: 0, count: n), mic: Signals.noise(n, seed: 1),
                    aecStats: AECStats(), frames: 100)
        XCTAssertEqual(r.score, 0, accuracy: 1e-6)
    }

    func testCoupledSignalsRaiseScoreAndFindDelay() {
        let d = CouplingDetector()
        let n = 480 * 200
        let render = Signals.noise(n, seed: 2)
        let delay = Int(0.045 * 48000)
        var mic = [Float](repeating: 0, count: n)
        for i in delay..<n { mic[i] = 0.5 * render[i - delay] }
        let stats = AECStats(delayMs: 45, delayStddevMs: 1, echoReturnLossEnhancement: 20, valid: true)
        let r = run(d, render: render, mic: mic, aecStats: stats, frames: 200)
        XCTAssertGreaterThan(r.score, 0.8)
        XCTAssertGreaterThanOrEqual(r.stableWindows, 5)
        XCTAssertGreaterThan(abs(r.correlation), 0.9)
        XCTAssertEqual(r.delayMs, 45)
    }

    func testCouplingFoundWithoutAECHint() {
        let d = CouplingDetector()
        let n = 480 * 200
        let render = Signals.noise(n, seed: 3)
        let delay = Int(0.120 * 48000)
        var mic = [Float](repeating: 0, count: n)
        for i in delay..<n { mic[i] = 0.4 * render[i - delay] }
        let r = run(d, render: render, mic: mic, aecStats: AECStats(), frames: 200)
        XCTAssertGreaterThan(abs(r.correlation), 0.85)
        XCTAssertEqual(Double(r.delayMs), 120, accuracy: 3)
        XCTAssertGreaterThan(r.score, 0.5)
    }

    func testUncoupledSignalsStayLow() {
        let d = CouplingDetector()
        let n = 480 * 200
        let r = run(d, render: Signals.noise(n, seed: 4), mic: Signals.noise(n, seed: 999),
                    aecStats: AECStats(delayMs: 40, delayStddevMs: 1, valid: true), frames: 200)
        XCTAssertLessThan(r.score, 0.2)
        XCTAssertEqual(r.stableWindows, 0)
    }

    func testDivergenceHalvesScore() {
        let n = 480 * 200
        let render = Signals.noise(n, seed: 5)
        let mic = render.map { 0.5 * $0 }
        let good = run(CouplingDetector(), render: render, mic: mic,
                       aecStats: AECStats(delayMs: 0, echoReturnLossEnhancement: 20, divergentFilterFraction: 0, valid: true), frames: 200)
        let bad = run(CouplingDetector(), render: render, mic: mic,
                      aecStats: AECStats(delayMs: 0, echoReturnLossEnhancement: 20, divergentFilterFraction: 0.9, valid: true), frames: 200)
        XCTAssertLessThan(bad.score, 0.6 * good.score)
    }

    func testRenderActivityHangover() {
        var d = RenderActivityDetector()
        d.hangoverFrames = 3
        XCTAssertTrue(d.update(renderRmsDb: -20).isActive)
        XCTAssertTrue(d.update(renderRmsDb: -90).isActive)
        XCTAssertTrue(d.update(renderRmsDb: -90).isActive)
        XCTAssertTrue(d.update(renderRmsDb: -90).isActive)
        XCTAssertFalse(d.update(renderRmsDb: -90).isActive)
    }
}
