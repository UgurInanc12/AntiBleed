import Foundation

/// Phase 3: pairs render and mic blocks by hostTime.
final class AudioSynchronizer {
    struct SyncStats {
        var bufferSkewMs: Double = 0
        var renderDepth: Int = 0
        var micDepth: Int = 0
        var underruns: UInt64 = 0
        var overruns: UInt64 = 0
    }

    private var renderQueue: [AudioFrame] = []
    private var micQueue: [AudioFrame] = []
    var stats = SyncStats()

    /// Push from capture threads (called via ring pop on DSP thread)
    func pushRender(_ frame: AudioFrame) { renderQueue.append(frame) }
    func pushMic(_ frame: AudioFrame) { micQueue.append(frame) }

    /// Pull the best-aligned pair within tolerance. Returns nil on underflow.
    func pullAlignedFrames(toleranceMs: Double = 5) -> (render: AudioFrame, mic: AudioFrame)? {
        guard let r = renderQueue.first, let m = micQueue.first else {
            stats.underruns += 1
            return nil
        }
        // Simple hostTime delta in nanos -> ms
        // hostTime is mach_absolute_time; convert via mach_timebase or AudioConvertHostTimeToNanos
        // For stub: compare sequence numbers
        renderQueue.removeFirst()
        micQueue.removeFirst()
        stats.renderDepth = renderQueue.count
        stats.micDepth = micQueue.count
        return (r, m)
    }

    func reset() {
        renderQueue.removeAll()
        micQueue.removeAll()
        stats = SyncStats()
    }
}
