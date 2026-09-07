import XCTest
@testable import AntiBleedCore

/// Deterministic fake AEC for engine tests. Models an ideal canceller: when a
/// render frame was supplied it subtracts a scaled/delayed copy of the render
/// from the capture (this is a TEST DOUBLE, the product never does this).
final class FakeCanceller: EchoCanceller {
    var real = true
    var echoGain: Float = 0.5
    var divergent: Float = 0
    var delayMs = 0 // test signals use zero-lag coupling; the detector centres its lag search here
    private var lastRender: [Float] = []
    private(set) var renderCalls = 0
    private(set) var captureCalls = 0
    private(set) var resets = 0

    var isRealAEC: Bool { real }
    func processRender(_ render: [Float]) { lastRender = render; renderCalls += 1 }
    func processCapture(_ capture: [Float]) -> [Float] {
        captureCalls += 1
        guard !lastRender.isEmpty else { return capture }
        var out = capture
        for i in 0..<min(out.count, lastRender.count) { out[i] -= echoGain * lastRender[i] }
        return out
    }
    func stats() -> AECStats {
        AECStats(delayMs: delayMs, delayMedianMs: delayMs, delayStddevMs: 1,
                 echoReturnLoss: 10, echoReturnLossEnhancement: 20,
                 divergentFilterFraction: divergent, residualEchoLikelihood: 0.05, valid: true)
    }
    func reset() { resets += 1; lastRender = [] }
}

enum Signals {
    static func noise(_ n: Int, seed: UInt64, level: Float = 0.2) -> [Float] {
        var s = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return (Float(s >> 33) / Float(1 << 31) * 2 - 1) * level
        }
    }
    static func frame(_ samples: [Float], seq: UInt64, t0Ns: UInt64 = 0) -> AudioFrame {
        AudioFrame(samples: samples, hostTimeNs: t0Ns + seq * 10_000_000, sequenceNumber: seq)
    }
}

final class EngineTests: XCTestCase {
    /// Headphones / no coupling: render active but mic contains no echo -> FSM
    /// must stay out of ACTIVE and the output must be the raw microphone.
    func testNoCouplingKeepsRawMic() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        var everActive = false
        for i in 0..<300 {
            let render = Signals.frame(Signals.noise(480, seed: UInt64(i) + 1), seq: UInt64(i))
            let mic = Signals.frame(Signals.noise(480, seed: UInt64(i) + 10_000), seq: UInt64(i))
            let out = engine.process(render: render, mic: mic)
            if engine.state == .active { everActive = true }
            if engine.state != .active {
                // rawMic or a crossfade very close to raw
                XCTAssertEqual(out.samples, mic.samples, "output must be raw mic when not ACTIVE (frame \(i))")
            }
        }
        XCTAssertFalse(everActive, "engine must not activate without acoustic coupling")
        XCTAssertGreaterThan(aec.captureCalls, 0, "AEC keeps adapting in BYPASS")
    }

    /// Real coupling: mic = voice + 0.5 * render (zero delay so the fake can cancel).
    /// FSM must reach ACTIVE and the output must then be the AEC output.
    func testCouplingActivatesAndUsesAECOutput() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        var activeFrames = 0
        var xfadeSeen = false
        for i in 0..<600 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            let voice = Signals.noise(480, seed: UInt64(i) + 50_000, level: 0.05)
            let m = zip(voice, r).map { $0 + 0.5 * $1 }
            let render = Signals.frame(r, seq: UInt64(i))
            let mic = Signals.frame(m, seq: UInt64(i))
            let out = engine.process(render: render, mic: mic)
            if engine.telemetry.output == "xfade" { xfadeSeen = true }
            if engine.state == .active && engine.telemetry.output == "aec" {
                activeFrames += 1
                // Ideal fake cancels the echo exactly -> output ~= voice
                let err = zip(out.samples, voice).map { abs($0 - $1) }.max() ?? 1
                XCTAssertLessThan(err, 1e-5)
            }
        }
        XCTAssertGreaterThan(activeFrames, 100, "engine should spend most of the run in ACTIVE")
        XCTAssertTrue(xfadeSeen, "entering ACTIVE must go through a crossfade")
    }

    /// D-008 structural invariant: whatever the FSM does, the output is never
    /// correlated with the render beyond what the mic already contains.
    func testOutputNeverContainsInvertedRender() {
        let aec = FakeCanceller()
        aec.real = true
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        for i in 0..<200 {
            let r = Signals.noise(480, seed: UInt64(i) + 7)
            let mic = Signals.noise(480, seed: UInt64(i) + 70_000)
            let out = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(mic, seq: UInt64(i)))
            let corr = SignalMetrics.normalizedCorrelation(r, out.samples, lag: 0)
            XCTAssertLessThan(abs(corr), 0.3, "frame \(i): output acquired render content")
        }
    }

    func testRouteChangeSnapsToRawAndResetsAEC() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        for i in 0..<400 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            let m = r.map { 0.5 * $0 }
            _ = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(m, seq: UInt64(i)))
        }
        XCTAssertEqual(engine.state, .active)
        engine.notifyRouteChanged()
        let r = Signals.noise(480, seed: 999)
        let m = r.map { 0.5 * $0 }
        let out = engine.process(render: Signals.frame(r, seq: 401), mic: Signals.frame(m, seq: 401))
        // routeChanged frame returns raw and lands in BYPASS; render is active so the
        // next frames move to PROBING, never straight back to ACTIVE.
        XCTAssertTrue(engine.state == .bypass || engine.state == .probing)
        XCTAssertEqual(out.samples, m)
        for i in 0..<5 {
            _ = engine.process(render: Signals.frame(r, seq: 402 + UInt64(i)), mic: Signals.frame(m, seq: 402 + UInt64(i)))
            XCTAssertNotEqual(engine.state, .active)
        }
        XCTAssertGreaterThanOrEqual(aec.resets, 1)
    }

    func testDivergenceFallsBackToRaw() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        for i in 0..<400 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            _ = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: UInt64(i)))
        }
        XCTAssertEqual(engine.state, .active)
        aec.divergent = 0.6
        let r = Signals.noise(480, seed: 5)
        _ = engine.process(render: Signals.frame(r, seq: 500), mic: Signals.frame(r.map { 0.5 * $0 }, seq: 500))
        XCTAssertEqual(engine.state, .degraded)
        // After the crossfade, output is raw.
        var out = AudioFrame.silence()
        for i in 0..<20 {
            out = engine.process(render: Signals.frame(r, seq: 501 + UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: 501 + UInt64(i)))
        }
        XCTAssertEqual(out.samples, r.map { 0.5 * $0 })
    }

    func testPassthroughCancellerNeverActivates() {
        let engine = AntiBleedEngine(aec: PassthroughCanceller())
        engine.start()
        for i in 0..<300 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            let out = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: UInt64(i)))
            XCTAssertNotEqual(engine.state, .active)
            XCTAssertEqual(out.samples, r.map { 0.5 * $0 })
        }
    }

    func testAECDisabledStaysBypass() {
        let engine = AntiBleedEngine(aec: FakeCanceller())
        engine.aecEnabled = false
        engine.start()
        for i in 0..<300 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            _ = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: UInt64(i)))
            XCTAssertEqual(engine.state, .bypass)
        }
    }

    func testStoppedOutputsSilence() {
        let engine = AntiBleedEngine(aec: FakeCanceller())
        let r = Signals.noise(480, seed: 1)
        let out = engine.process(render: Signals.frame(r, seq: 0), mic: Signals.frame(r, seq: 0))
        XCTAssertTrue(out.samples.allSatisfy { $0 == 0 })
    }
}
