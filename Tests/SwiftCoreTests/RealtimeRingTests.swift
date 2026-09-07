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

    func testBlockRingRejectsOversizedBlock() {
        let ring = abm_ring_create(2, 8)!
        defer { abm_ring_destroy(ring) }
        let big = [Float](repeating: 1, count: 16)
        XCTAssertEqual(abm_ring_push(ring, big, nil, 16, 0, 0, 1), -1)
        XCTAssertEqual(abm_ring_available(ring), 0)
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

    func testFifoConcurrentSPSC() {
        let f = abm_fifo_create(4096)!
        defer { abm_fifo_destroy(f) }
        let total = 200_000
        let producer = Thread {
            var i = 0
            var block = [Float](repeating: 0, count: 480)
            while i < total {
                if Int(abm_fifo_available(f)) + 480 <= 4096 {
                    for k in 0..<480 { block[k] = Float(i + k) }
                    _ = abm_fifo_push(f, block, 480); i += 480
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
                _ = abm_fifo_pop(f, &out, 480)
                for k in 0..<480 { if out[k] != expected + Float(k) { ok = false } }
                expected += 480; got += 480
            }
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(abm_fifo_overruns(f), 0)
        XCTAssertEqual(abm_fifo_underruns(f), 0)
    }
}
