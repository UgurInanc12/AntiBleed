import XCTest
import AntiBleedRealtime

/// Tests for the C real-time rings used between Core Audio IOProcs and the DSP thread.
final class RealtimeRingTests: XCTestCase {
    func testBlockRingRoundTripAndMetadata() {
        let ring = abm_ring_create(4, 512)!
        defer { abm_ring_destroy(ring) }
        let mic = (0..<256).map { Float($0) }
        let render = (0..<256).map { Float(-$0) }
        XCTAssertEqual(abm_ring_push(ring, mic, render, 256, 123_456, 42.0, 1.0), 0)
        var view = abm_block_view_t()
        XCTAssertTrue(abm_ring_pop(ring, &view))
        XCTAssertEqual(view.frames, 256)
        XCTAssertEqual(view.host_time_ns, 123_456)
        XCTAssertEqual(view.sample_time, 42.0)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: view.mic, count: 256)), mic)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: view.render, count: 256)), render)
        XCTAssertFalse(abm_ring_pop(ring, &view))
    }

    func testBlockRingOverflowDropsOldest() {
        let ring = abm_ring_create(2, 8)!
        defer { abm_ring_destroy(ring) }
        for i in 0..<3 {
            let block = [Float](repeating: Float(i), count: 8)
            _ = abm_ring_push(ring, block, nil, 8, UInt64(i), 0, 1)
        }
        XCTAssertEqual(abm_ring_overruns(ring), 1)
        var view = abm_block_view_t()
        XCTAssertTrue(abm_ring_pop(ring, &view))
        XCTAssertEqual(view.host_time_ns, 1)
        XCTAssertEqual(view.render.pointee, 0) // nil render -> zeros
        XCTAssertTrue(abm_ring_pop(ring, &view))
        XCTAssertEqual(view.host_time_ns, 2)
    }

    func testBlockViewSurvivesProducerWrapUntilNextPop() {
        let ring = abm_ring_create(2, 8)!
        defer { abm_ring_destroy(ring) }
        _ = abm_ring_push(ring, [Float](repeating: 1, count: 8), nil, 8, 1, 0, 1)
        var view = abm_block_view_t()
        XCTAssertTrue(abm_ring_pop(ring, &view))
        for value in 2...5 {
            _ = abm_ring_push(ring, [Float](repeating: Float(value), count: 8), nil, 8, UInt64(value), 0, 1)
        }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: view.mic, count: 8)), [Float](repeating: 1, count: 8))
        XCTAssertEqual(view.host_time_ns, 1)
    }

    func testBlockRingRejectsOversizedBlock() {
        let ring = abm_ring_create(2, 8)!
        defer { abm_ring_destroy(ring) }
        let big = [Float](repeating: 1, count: 16)
        XCTAssertEqual(abm_ring_push(ring, big, nil, 16, 0, 0, 1), -1)
        XCTAssertEqual(abm_ring_available(ring), 0)
    }

    func testFifoResetDiscardsOldAudioAndAcceptsNewAudio() {
        let fifo = abm_fifo_create(4)!
        defer { abm_fifo_destroy(fifo) }
        _ = abm_fifo_push(fifo, [1, 2, 3, 4], 4)
        XCTAssertTrue(abm_fifo_try_reset(fifo))
        XCTAssertEqual(abm_fifo_available(fifo), 0)
        _ = abm_fifo_push(fifo, [9, 10], 2)
        var out = [Float](repeating: -1, count: 4)
        XCTAssertEqual(abm_fifo_pop(fifo, &out, 4), 2)
        XCTAssertEqual(out, [9, 10, 0, 0])
    }

    func testFifoUnderflowIsSilenceAndCounted() {
        let f = abm_fifo_create(16)!
        defer { abm_fifo_destroy(f) }
        _ = abm_fifo_push(f, [1, 2, 3, 4], 4)
        var out = [Float](repeating: 99, count: 8)
        XCTAssertEqual(abm_fifo_pop(f, &out, 8), 4)
        XCTAssertEqual(out, [1, 2, 3, 4, 0, 0, 0, 0])
        XCTAssertEqual(abm_fifo_underruns(f), 4)
    }

    func testFifoOverflowDropsOldestAndWraps() {
        let f = abm_fifo_create(6)!
        defer { abm_fifo_destroy(f) }
        _ = abm_fifo_push(f, [1, 2, 3, 4], 4)
        XCTAssertEqual(abm_fifo_push(f, [5, 6, 7, 8], 4), 2) // 1,2 dropped
        XCTAssertEqual(abm_fifo_overruns(f), 2)
        var out = [Float](repeating: 0, count: 6)
        XCTAssertEqual(abm_fifo_pop(f, &out, 6), 6)
        XCTAssertEqual(out, [3, 4, 5, 6, 7, 8])
    }

    func testFifoOversizedPushCountsEveryDroppedSample() {
        let fifo = abm_fifo_create(4)!
        defer { abm_fifo_destroy(fifo) }
        XCTAssertEqual(abm_fifo_push(fifo, [1, 2, 3, 4, 5, 6], 6), 2)
        XCTAssertEqual(abm_fifo_overruns(fifo), 2)
    }

    func testFifoConcurrentOverflowPreservesSampleOrder() {
        let f = abm_fifo_create(64)!
        defer { abm_fifo_destroy(f) }
        let handle = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(f)))
        let done = DispatchGroup()
        done.enter()
        Thread {
            defer { done.leave() }
            let fifo = OpaquePointer(bitPattern: handle)!
            var block = [Float](repeating: 0, count: 32)
            for i in 0..<20_000 {
                for k in block.indices { block[k] = Float(i * 32 + k + 1) }
                _ = abm_fifo_push(fifo, block, 32)
            }
        }.start()
        var last: Float = 0
        var out = [Float](repeating: 0, count: 17)
        var ordered = true
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let n = Int(abm_fifo_pop(f, &out, 17))
            for value in out.prefix(n) {
                if value <= last { ordered = false }
                last = value
            }
            if done.wait(timeout: .now()) == .success && abm_fifo_available(f) == 0 { break }
        }
        done.wait()
        XCTAssertTrue(ordered, "Overflow must not replay, reorder or tear samples")
        XCTAssertLessThanOrEqual(abm_fifo_available(f), 64)
    }

    func testFifoConcurrentSPSC() {
        let f = abm_fifo_create(4096)!
        defer { abm_fifo_destroy(f) }
        let total = 200_000
        let fifo = UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(f))) // Sendable handle for the thread
        let producer = Thread {
            let f = OpaquePointer(bitPattern: fifo)!
            var i = 0
            var block = [Float](repeating: 0, count: 480)
            while i < total {
                if Int(abm_fifo_available(f)) + 480 <= 4096 {
                    for k in 0..<480 { block[k] = Float(i + k) }
                    if abm_fifo_push(f, block, 480) == 0 { i += 480 }
                }
            }
        }
        producer.start()
        var got = 0
        var expected: Float = 0
        var out = [Float](repeating: 0, count: 480)
        var ok = true
        while got < total {
            if abm_fifo_available(f) >= 480 {
                guard abm_fifo_pop(f, &out, 480) == 480 else { continue }
                for k in 0..<480 { if out[k] != expected + Float(k) { ok = false } }
                expected += 480; got += 480
            }
        }
        XCTAssertTrue(ok)
        // Rejected writes are retried; contended reads return silence, not stale data.
    }
}
