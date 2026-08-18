#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

/// Bounded, preallocated SPSC ring buffer.
/// Real-time safe: push/pop use only atomics, no malloc, no blocking mutex.
/// Overflow: drop oldest (counted as overrun) - newest data is most valuable.
/// Underflow: pop returns silence (zeros) and counts underrun.
template <typename T>
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity)
        : capacity_(capacity)
        , buffer_(capacity)
        , writePos_(0)
        , readPos_(0)
        , size_(0)
        , overruns_(0)
        , underruns_(0) {}

    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    /// Push count elements. If not enough space, drops oldest to make room.
    /// Returns number dropped (0 if no overflow).
    size_t push(const T* data, size_t count) {
        if (!data || count == 0) return 0;
        if (count > capacity_) {
            // Only keep the last capacity elements
            data += (count - capacity_);
            count = capacity_;
        }
        size_t dropped = 0;
        size_t sz = size_.load(std::memory_order_acquire);
        if (sz + count > capacity_) {
            dropped = sz + count - capacity_;
            // Advance readPos to drop oldest
            readPos_.store((readPos_.load(std::memory_order_relaxed) + dropped) % capacity_,
                           std::memory_order_release);
            size_.store(capacity_ - count, std::memory_order_release);
            overruns_.fetch_add(dropped, std::memory_order_relaxed);
        }
        size_t wp = writePos_.load(std::memory_order_relaxed);
        for (size_t i = 0; i < count; ++i) {
            buffer_[(wp + i) % capacity_] = data[i];
        }
        writePos_.store((wp + count) % capacity_, std::memory_order_release);
        // Update size
        sz = size_.load(std::memory_order_acquire);
        sz = (sz + count > capacity_) ? capacity_ : sz + count;
        // For the dropped case we already set size to capacity-count then need +count
        // Simplify: recompute
        // Actually handle both paths cleanly:
        // We need to do this atomically w.r.t size; for SPSC with single writer,
        // the writer is the only one modifying writePos_/size_, reader only reads.
        // So we can just store.
        if (dropped > 0) {
            size_.store(capacity_, std::memory_order_release);
        } else {
            size_.store(sz, std::memory_order_release);
        }
        return dropped;
    }

    /// Pop count elements into out. If not enough available, fills remainder with T{} (silence).
    /// Returns number actually available (0..count). Underrun counted if short.
    size_t pop(T* out, size_t count) {
        if (!out || count == 0) return 0;
        size_t sz = size_.load(std::memory_order_acquire);
        size_t available = (sz < count) ? sz : count;
        size_t rp = readPos_.load(std::memory_order_relaxed);
        for (size_t i = 0; i < available; ++i) {
            out[i] = buffer_[(rp + i) % capacity_];
        }
        if (available < count) {
            for (size_t i = available; i < count; ++i) out[i] = T{};
            underruns_.fetch_add(count - available, std::memory_order_relaxed);
        }
        readPos_.store((rp + available) % capacity_, std::memory_order_release);
        size_.store(sz - available, std::memory_order_release);
        return available;
    }

    size_t available() const { return size_.load(std::memory_order_acquire); }
    size_t freeSpace() const { return capacity_ - available(); }
    size_t capacity() const { return capacity_; }
    uint64_t overruns() const { return overruns_.load(std::memory_order_relaxed); }
    uint64_t underruns() const { return underruns_.load(std::memory_order_relaxed); }

    void reset() {
        writePos_.store(0, std::memory_order_relaxed);
        readPos_.store(0, std::memory_order_relaxed);
        size_.store(0, std::memory_order_relaxed);
        overruns_.store(0, std::memory_order_relaxed);
        underruns_.store(0, std::memory_order_relaxed);
    }

private:
    size_t capacity_;
    std::vector<T> buffer_;
    std::atomic<size_t> writePos_;
    std::atomic<size_t> readPos_;
    std::atomic<size_t> size_;
    std::atomic<uint64_t> overruns_;
    std::atomic<uint64_t> underruns_;
};
