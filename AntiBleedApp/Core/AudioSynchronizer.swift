import Foundation

/// Pairs render (far-end reference) and mic (near-end) frames by host time
/// (PLAN 11, D-011). Inside a private aggregate device both streams share a
/// clock, so residual skew is small and stable; this class still guards
/// against startup offsets, dropped callbacks and device hiccups.
///
/// Policy:
///  - Frames are matched when |t_mic - t_render| <= tolerance.
///  - If one side is older than the other by more than the tolerance it is
///    stale and discarded (counted), so a burst of dropped callbacks cannot
///    permanently shift the alignment.
///  - If either queue is empty the caller sees nil (underrun) and must not feed
///    AEC3 a fabricated frame.
///  - Queue depth is bounded; overflow drops the oldest (newest audio wins).
public final class AudioSynchronizer {
    public struct SyncStats: Equatable {
        public var bufferSkewMs: Double = 0        // last matched t_mic - t_render
        public var skewMeanMs: Double = 0
        public var skewAbsMaxMs: Double = 0
        public var renderDepth: Int = 0
        public var micDepth: Int = 0
        public var pairs: UInt64 = 0
        public var underruns: UInt64 = 0
        public var overruns: UInt64 = 0
        public var staleDropsRender: UInt64 = 0
        public var staleDropsMic: UInt64 = 0
        public init() {}
    }

    public var toleranceMs: Double
    public let maxDepth: Int
    public private(set) var stats = SyncStats()

    private var renderQueue: [AudioFrame] = []
    private var micQueue: [AudioFrame] = []
    private var skewAccum: Double = 0

    public init(toleranceMs: Double = 5, maxDepth: Int = 50) {
        self.toleranceMs = toleranceMs
        self.maxDepth = maxDepth
        renderQueue.reserveCapacity(maxDepth)
        micQueue.reserveCapacity(maxDepth)
    }

    public func pushRender(_ frame: AudioFrame) { enqueue(frame, into: &renderQueue) }
    public func pushMic(_ frame: AudioFrame) { enqueue(frame, into: &micQueue) }

    private func enqueue(_ frame: AudioFrame, into queue: inout [AudioFrame]) {
        if queue.count >= maxDepth {
            queue.removeFirst()
            stats.overruns += 1
        }
        queue.append(frame)
    }

    /// Returns the next time-aligned (render, mic) pair or nil on underrun.
    public func pullAlignedFrames() -> (render: AudioFrame, mic: AudioFrame)? {
        let tolNs = Int64(toleranceMs * 1_000_000)
        while true {
            guard let r = renderQueue.first, let m = micQueue.first else {
                stats.underruns += 1
                updateDepths()
                return nil
            }
            // Untimestamped frames (tests/stubs) pair in order.
            if r.hostTimeNs == 0 || m.hostTimeNs == 0 {
                renderQueue.removeFirst(); micQueue.removeFirst()
                record(skewNs: 0)
                return (r, m)
            }
            let delta = Int64(bitPattern: m.hostTimeNs) - Int64(bitPattern: r.hostTimeNs)
            if abs(delta) <= tolNs {
                renderQueue.removeFirst(); micQueue.removeFirst()
                record(skewNs: delta)
                return (r, m)
            }
            if delta > 0 {
                // Render frame is older than the mic frame beyond tolerance: stale.
                renderQueue.removeFirst()
                stats.staleDropsRender += 1
            } else {
                micQueue.removeFirst()
                stats.staleDropsMic += 1
            }
        }
    }

    private func record(skewNs: Int64) {
        let ms = Double(skewNs) / 1_000_000
        stats.pairs += 1
        stats.bufferSkewMs = ms
        skewAccum += ms
        stats.skewMeanMs = skewAccum / Double(stats.pairs)
        stats.skewAbsMaxMs = max(stats.skewAbsMaxMs, abs(ms))
        updateDepths()
    }

    private func updateDepths() {
        stats.renderDepth = renderQueue.count
        stats.micDepth = micQueue.count
    }

    public func reset() {
        renderQueue.removeAll(keepingCapacity: true)
        micQueue.removeAll(keepingCapacity: true)
        stats = SyncStats()
        skewAccum = 0
    }
}
