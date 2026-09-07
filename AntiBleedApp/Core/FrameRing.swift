import Foundation

/// Bounded SPSC ring for AudioFrame values crossing from a Core Audio callback
/// thread to the DSP worker. Preallocated storage; push/pop never allocate
/// (frames are moved by value; the sample arrays are preallocated by the
/// producer's staging buffers). Overflow drops the oldest frame (counted).
public final class FrameRing {
    private var slots: [AudioFrame?]
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
    public private(set) var overruns: UInt64 = 0
    public private(set) var underruns: UInt64 = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        slots = [AudioFrame?](repeating: nil, count: self.capacity)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    /// Returns true if an old frame had to be dropped.
    @discardableResult
    public func push(_ frame: AudioFrame) -> Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var dropped = false
        if count == capacity {
            readIndex = (readIndex + 1) % capacity
            count -= 1
            overruns += 1
            dropped = true
        }
        slots[writeIndex] = frame
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        return dropped
    }

    public func pop() -> AudioFrame? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        guard count > 0 else { underruns += 1; return nil }
        let f = slots[readIndex]
        slots[readIndex] = nil
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return f
    }

    public func peek() -> AudioFrame? {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count > 0 ? slots[readIndex] : nil
    }

    public var available: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    public func reset() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for i in 0..<capacity { slots[i] = nil }
        writeIndex = 0; readIndex = 0; count = 0
        overruns = 0; underruns = 0
    }
}

#if !canImport(Darwin)
// os_unfair_lock shim for non-Darwin builds (Windows/Linux unit tests).
public struct os_unfair_lock_s { fileprivate var m = NSLock() }
@inline(__always) func os_unfair_lock_lock(_ l: UnsafeMutablePointer<os_unfair_lock_s>) { l.pointee.m.lock() }
@inline(__always) func os_unfair_lock_unlock(_ l: UnsafeMutablePointer<os_unfair_lock_s>) { l.pointee.m.unlock() }
#endif
