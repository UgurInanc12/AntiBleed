import XCTest
@testable import AntiBleedCore

final class SynchronizerTests: XCTestCase {
    private func f(_ ns: UInt64, seq: UInt64 = 0, v: Float = 0.1) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: v, count: 480), hostTimeNs: ns, sequenceNumber: seq)
    }

    func testAlignedPairsWithinTolerance() {
        let s = AudioSynchronizer(toleranceMs: 5)
        s.pushRender(f(1_000_000_000))
        s.pushMic(f(1_002_000_000)) // +2 ms
        let p = s.pullAlignedFrames()
        XCTAssertNotNil(p)
        XCTAssertEqual(s.stats.bufferSkewMs, 2, accuracy: 1e-6)
        XCTAssertEqual(s.stats.pairs, 1)
    }

    func testStaleRenderIsDropped() {
        let s = AudioSynchronizer(toleranceMs: 5)
        // render frames at t=0,10,20 ms; mic starts at 20 ms -> first two renders are stale
        let t0: UInt64 = 1_000_000_000
        for i in 0..<3 { s.pushRender(f(t0 + UInt64(i) * 10_000_000, seq: UInt64(i))) }
        s.pushMic(f(t0 + 20_000_000, seq: 0))
        let p = s.pullAlignedFrames()
        XCTAssertEqual(p?.render.sequenceNumber, 2)
        XCTAssertEqual(s.stats.staleDropsRender, 2)
        XCTAssertEqual(s.stats.staleDropsMic, 0)
    }

    func testStaleMicIsDropped() {
        let s = AudioSynchronizer(toleranceMs: 5)
        let t0: UInt64 = 1_000_000_000
        for i in 0..<3 { s.pushMic(f(t0 + UInt64(i) * 10_000_000, seq: UInt64(i))) }
        s.pushRender(f(t0 + 20_000_000, seq: 0))
        let p = s.pullAlignedFrames()
        XCTAssertEqual(p?.mic.sequenceNumber, 2)
        XCTAssertEqual(s.stats.staleDropsMic, 2)
    }

    func testUnderrunReturnsNilNeverFabricates() {
        let s = AudioSynchronizer()
        s.pushRender(f(0))
        XCTAssertNil(s.pullAlignedFrames())
        XCTAssertEqual(s.stats.underruns, 1)
    }

    func testDepthBoundedDropsOldest() {
        let s = AudioSynchronizer(toleranceMs: 5, maxDepth: 3)
        let t0: UInt64 = 1_000_000_000
        for i in 0..<5 { s.pushRender(f(t0 + UInt64(i) * 10_000_000, seq: UInt64(i))) }
        XCTAssertEqual(s.stats.overruns, 2)
        s.pushMic(f(t0 + 40_000_000))
        let p = s.pullAlignedFrames()
        XCTAssertEqual(p?.render.sequenceNumber, 4)
    }

    func testUntimestampedFramesPairInOrder() {
        let s = AudioSynchronizer()
        s.pushRender(f(0, seq: 1)); s.pushMic(f(0, seq: 1))
        s.pushRender(f(0, seq: 2)); s.pushMic(f(0, seq: 2))
        XCTAssertEqual(s.pullAlignedFrames()?.mic.sequenceNumber, 1)
        XCTAssertEqual(s.pullAlignedFrames()?.mic.sequenceNumber, 2)
        XCTAssertNil(s.pullAlignedFrames())
    }

    func testLongRunSkewStaysBounded() {
        // 30 minutes of simulated frames with 0.3 ms jitter and a 1 ms constant offset.
        let s = AudioSynchronizer(toleranceMs: 5)
        var rng = SystemRandomNumberGenerator()
        let frames = 30 * 60 * 100
        var pairs = 0
        for i in 0..<frames {
            let base = 1_000_000_000 + UInt64(i) * 10_000_000
            let jitter = UInt64.random(in: 0...300_000, using: &rng)
            s.pushRender(f(base + jitter, seq: UInt64(i)))
            s.pushMic(f(base + 1_000_000 + jitter / 2, seq: UInt64(i)))
            if s.pullAlignedFrames() != nil { pairs += 1 }
        }
        XCTAssertEqual(pairs, frames)
        XCTAssertLessThan(s.stats.skewAbsMaxMs, 1.5)
        XCTAssertEqual(s.stats.staleDropsMic + s.stats.staleDropsRender, 0)
    }
}

final class FrameAssemblerTests: XCTestCase {
    func testVariableBlockSizesYieldExact480Frames() {
        let a = FrameAssembler()
        var total = 0
        var frames: [AudioFrame] = []
        for size in [128, 256, 512, 1024, 77, 3, 480] {
            frames += a.push([Float](repeating: 0.1, count: size), sampleRate: 48000, channels: 1, hostTimeNs: 0)
            total += size
        }
        XCTAssertTrue(frames.allSatisfy { $0.samples.count == 480 })
        XCTAssertEqual(frames.count, total / 480)
        XCTAssertEqual(a.pendingSamples, total % 480)
        XCTAssertEqual(frames.map(\.sequenceNumber), Array(0..<UInt64(frames.count)))
    }

    func testStereoDownmix() {
        let a = FrameAssembler()
        let stereo = (0..<480).flatMap { _ in [Float(0.4), Float(0.6)] }
        let frames = a.push(stereo, sampleRate: 48000, channels: 2, hostTimeNs: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].samples[0], 0.5, accuracy: 1e-6)
    }

    func testHostTimeInterpolatedPerFrame() {
        let a = FrameAssembler()
        let frames = a.push([Float](repeating: 0, count: 1440), sampleRate: 48000, channels: 1, hostTimeNs: 1_000_000_000)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].hostTimeNs, 1_000_000_000)
        XCTAssertEqual(frames[1].hostTimeNs, 1_010_000_000)
        XCTAssertEqual(frames[2].hostTimeNs, 1_020_000_000)
    }

    func testResample44100To48000PreservesToneAndCount() {
        let a = FrameAssembler()
        let inRate = 44100.0
        let n = 44100 // 1 s
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / inRate)) }
        var frames: [AudioFrame] = []
        var i = 0
        while i < n { let c = min(512, n - i); frames += a.push(Array(tone[i..<i + c]), sampleRate: inRate, channels: 1, hostTimeNs: 0); i += c }
        let outCount = frames.count * 480 + a.pendingSamples
        XCTAssertEqual(Double(outCount), 48000, accuracy: 3) // ratio preserved
        // Tone continuity: no clicks -> adjacent-sample jumps stay small for a 1 kHz tone at 48 kHz (< ~0.14).
        let all = frames.flatMap(\.samples)
        var maxJump: Float = 0
        for k in 1..<all.count { maxJump = max(maxJump, abs(all[k] - all[k - 1])) }
        XCTAssertLessThan(maxJump, 0.2)
        // RMS of a unit sine is 0.707
        XCTAssertEqual(SignalMetrics.rms(Array(all.suffix(4800))), 0.707, accuracy: 0.03)
    }
}

final class FrameRingTests: XCTestCase {
    func testOverflowDropsOldestAndCounts() {
        let r = FrameRing(capacity: 3)
        for i in 0..<5 { r.push(AudioFrame(samples: [Float(i)], sequenceNumber: UInt64(i))) }
        XCTAssertEqual(r.overruns, 2)
        XCTAssertEqual(r.pop()?.sequenceNumber, 2)
        XCTAssertEqual(r.pop()?.sequenceNumber, 3)
        XCTAssertEqual(r.pop()?.sequenceNumber, 4)
        XCTAssertNil(r.pop())
        XCTAssertEqual(r.underruns, 1)
    }

    func testConcurrentProducerConsumer() {
        let r = FrameRing(capacity: 64)
        let n: UInt64 = 20_000
        let producer = Thread {
            var i: UInt64 = 0
            while i < n {
                if r.available < 64 { r.push(AudioFrame(samples: [0], sequenceNumber: i)); i += 1 }
            }
        }
        producer.start()
        var last: UInt64 = 0, got: UInt64 = 0, monotonic = true
        while got < n {
            if let f = r.pop() {
                if got > 0 && f.sequenceNumber <= last { monotonic = false }
                last = f.sequenceNumber; got += 1
            }
        }
        XCTAssertTrue(monotonic)
        XCTAssertEqual(r.overruns, 0)
    }
}

final class CrossfadeTests: XCTestCase {
    func testEqualPowerEndpoints() {
        let a = [Float](repeating: 1, count: 4), b = [Float](repeating: -1, count: 4)
        XCTAssertEqual(Crossfade.equalPower(a, b, progress: 0), a)
        XCTAssertEqual(Crossfade.equalPower(a, b, progress: 1).map { abs($0 + 1) < 1e-6 }, [true, true, true, true])
        let mid = Crossfade.equalPower(a, b, progress: 0.5)
        XCTAssertEqual(mid[0], 0, accuracy: 1e-6)
    }

    func testRampAdvances() {
        var ramp = CrossfadeRamp()
        ramp.start(frames: 4)
        var ps: [Float] = []
        while ramp.isActive { ps.append(ramp.progress); ramp.advance() }
        XCTAssertEqual(ps, [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(ramp.progress, 1)
    }
}
