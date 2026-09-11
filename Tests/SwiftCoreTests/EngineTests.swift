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

    /// D-020 headphones case: the reference output is no longer the macOS output.
    /// The AEC must disengage but the microphone must keep flowing, because the
    /// virtual mic is a live input in someone's call.
    func testReferenceOutputInactiveKeepsMicFlowing() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        // Reach ACTIVE with real coupling.
        for i in 0..<400 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            _ = engine.process(render: Signals.frame(r, seq: UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: UInt64(i)))
        }
        XCTAssertEqual(engine.state, .active)

        // User switches macOS output to headphones.
        engine.referenceOutputActive = false
        XCTAssertFalse(engine.aecUsable)
        var lastOut = AudioFrame.silence()
        var micStream: [[Float]] = []
        for i in 0..<200 {
            let r = Signals.noise(480, seed: UInt64(i) + 900)
            let mic = Signals.noise(480, seed: UInt64(i) + 90_000)
            micStream.append(mic)
            lastOut = engine.process(render: Signals.frame(r, seq: 500 + UInt64(i)), mic: Signals.frame(mic, seq: 500 + UInt64(i)))
            XCTAssertNotEqual(engine.state, .active)
            XCTAssertNotEqual(engine.telemetry.output, "silence", "mic must stay live (frame \(i))")
        }
        // Settled on the delay-aligned raw mic, not silence and not AEC output.
        XCTAssertEqual(engine.telemetry.output, "raw")
        XCTAssertFalse(lastOut.samples.allSatisfy { $0 == 0 })
        XCTAssertEqual(lastOut.samples, micStream[micStream.count - 1])
        // The AEC kept adapting so re-selecting the speakers converges instantly.
        XCTAssertGreaterThan(aec.captureCalls, 400)

        // Speakers selected again: processing may resume.
        engine.referenceOutputActive = true
        for i in 0..<400 {
            let r = Signals.noise(480, seed: UInt64(i) + 1)
            _ = engine.process(render: Signals.frame(r, seq: 900 + UInt64(i)), mic: Signals.frame(r.map { 0.5 * $0 }, seq: 900 + UInt64(i)))
        }
        XCTAssertEqual(engine.state, .active)
    }

    /// Measures how long the round trip speakers -> headphones -> speakers takes,
    /// so "it starts working again immediately" is a number and not a hope.
    /// The coupling detector needs a few stable windows of evidence before the
    /// FSM may re-arm, which is a real acoustic requirement, not a timer.
    func testReturningToSpeakersReEngagesQuickly() {
        let aec = FakeCanceller()
        let engine = AntiBleedEngine(aec: aec)
        engine.start()
        var seq: UInt64 = 0
        func run(_ frames: Int, coupled: Bool) -> Int {
            var framesUntilActive = -1
            for i in 0..<frames {
                let r = Signals.noise(480, seed: UInt64(i) + 1)
                let mic = coupled ? r.map { 0.5 * $0 } : Signals.noise(480, seed: UInt64(i) + 50_000)
                _ = engine.process(render: Signals.frame(r, seq: seq), mic: Signals.frame(mic, seq: seq))
                seq += 1
                if engine.state == .active && framesUntilActive < 0 { framesUntilActive = i + 1 }
            }
            return framesUntilActive
        }

        let coldStart = run(400, coupled: true)
        XCTAssertGreaterThan(coldStart, 0)
        XCTAssertEqual(engine.state, .active)

        // Headphones for 3 seconds.
        engine.referenceOutputActive = false
        _ = run(300, coupled: true)
        XCTAssertEqual(engine.state, .bypass)

        // Back to the speakers.
        engine.referenceOutputActive = true
        let reEngage = run(400, coupled: true)
        XCTAssertGreaterThan(reEngage, 0, "must return to ACTIVE after the speakers come back")
        XCTAssertEqual(engine.state, .active)
        // Never slower than the very first climb: the AEC kept adapting while bypassed.
        XCTAssertLessThanOrEqual(reEngage, coldStart)
        print("re-engage frames: cold=\(coldStart) afterHeadphones=\(reEngage) (10 ms each)")
    }
}

/// Canceller whose output lags its input by a fixed number of samples, like the
/// real AEC3 (measured at 430 samples / 9 ms). Cancels nothing; it exists to
/// exercise the raw-path alignment (D-020).
final class LaggingCanceller: EchoCanceller {
    let latency: Int
    private var history: [Float]
    init(latency: Int) {
        self.latency = latency
        // Pre-seeded with `latency` zeros so the very first frame already emits
        // the correct partial output, exactly like a delay line.
        history = [Float](repeating: 0, count: latency)
    }
    var isRealAEC: Bool { true }
    func processRender(_ render: [Float]) {}
    func processCapture(_ capture: [Float]) -> [Float] {
        history.append(contentsOf: capture)
        let start = history.count - capture.count - latency
        let out = Array(history[start..<(start + capture.count)])
        if history.count > capture.count + latency + 4800 {
            history.removeFirst(history.count - (capture.count + latency))
        }
        return out
    }
    func stats() -> AECStats { AECStats(delayMs: 0, delayStddevMs: 1, echoReturnLossEnhancement: 20, valid: true) }
    func reset() { history = [Float](repeating: 0, count: latency) }
}

final class PathAlignmentTests: XCTestCase {
    func testDelayLineDelaysExactly() {
        var d = DelayLine(delaySamples: 3)
        XCTAssertEqual(d.process([1, 2, 3, 4, 5]), [0, 0, 0, 1, 2])
        XCTAssertEqual(d.process([6, 7, 8]), [3, 4, 5])
    }

    func testZeroDelayIsIdentity() {
        var d = DelayLine(delaySamples: 0)
        XCTAssertEqual(d.process([1, 2, 3]), [1, 2, 3])
    }

    func testLatencyMeasurementFindsTheLag() {
        for latency in [0, 96, 430, 960] {
            let measured = EchoCancellerLatency.measure(LaggingCanceller(latency: latency))
            XCTAssertEqual(measured, latency, "latency \(latency) measured as \(measured)")
        }
    }

    func testPassthroughCancellerIsNotCalibrated() {
        XCTAssertEqual(EchoCancellerLatency.measure(PassthroughCanceller()), 0)
    }

    /// The point of the alignment: raw and AEC candidates describe the same
    /// instant, so a Bypass <-> Active switch is a gain change, not a time jump.
    func testEngineAlignsRawPathToAECLatency() {
        let latency = 430
        let engine = AntiBleedEngine(aec: LaggingCanceller(latency: latency))
        XCTAssertEqual(engine.pathAlignmentSamples, latency)
        engine.start()

        var micStream: [Float] = []
        var rawOut: [Float] = []
        var aecOut: [Float] = []
        for i in 0..<200 {
            let mic = Signals.noise(480, seed: UInt64(i) + 3_000)
            micStream.append(contentsOf: mic)
            let silence = [Float](repeating: 0, count: 480)
            _ = engine.process(render: Signals.frame(silence, seq: UInt64(i)), mic: Signals.frame(mic, seq: UInt64(i)))
            // Compare the two candidates directly rather than the FSM's pick.
            rawOut.append(contentsOf: engine.rawCandidateForTesting)
            aecOut.append(contentsOf: engine.aecCandidateForTesting)
        }
        // Both candidates must be the same signal at the same offset.
        let n = rawOut.count
        var maxDiff: Float = 0
        for i in 0..<n { maxDiff = max(maxDiff, abs(rawOut[i] - aecOut[i])) }
        XCTAssertLessThan(maxDiff, 1e-6, "raw and AEC candidates are not time aligned")
        // And that offset is the AEC latency behind the microphone.
        XCTAssertEqual(Array(rawOut[latency..<(latency + 480)]), Array(micStream[0..<480]))
    }

    func testAlignmentSurvivesRouteChange() {
        let engine = AntiBleedEngine(aec: LaggingCanceller(latency: 240))
        engine.start()
        for i in 0..<50 {
            let mic = Signals.noise(480, seed: UInt64(i))
            _ = engine.process(render: Signals.frame([Float](repeating: 0, count: 480), seq: UInt64(i)),
                               mic: Signals.frame(mic, seq: UInt64(i)))
        }
        engine.notifyRouteChanged()
        XCTAssertEqual(engine.pathAlignmentSamples, 240)
        // The delay line was cleared, so the first frames after the change are the
        // flushed zeros, not stale audio from before the route change.
        let mic = Signals.noise(480, seed: 12_345)
        let out = engine.process(render: Signals.frame([Float](repeating: 0, count: 480), seq: 51),
                                 mic: Signals.frame(mic, seq: 51))
        XCTAssertTrue(out.samples[0..<240].allSatisfy { $0 == 0 })
    }
}
