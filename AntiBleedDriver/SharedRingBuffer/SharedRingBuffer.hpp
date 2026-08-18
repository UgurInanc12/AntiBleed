#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

/// Driver-side SPSC shared ring. Bounded, preallocated, real-time safe.
/// Writer = Anti-Bleed_internal_writer (hidden output), Reader = Anti-Bleed_mic (visible input).
/// Underflow -> silence, overrun -> drop oldest. No malloc in I/O procs.
class SharedRingBuffer {
public:
    explicit SharedRingBuffer(size_t capacityFrames, size_t frameSize = 480);
    SharedRingBuffer(const SharedRingBuffer&) = delete;
    SharedRingBuffer& operator=(const SharedRingBuffer&) = delete;

    // Push interleaved Float32 frames (frameSize samples). Returns dropped frames.
    size_t push(const float* data, size_t numFrames);
    // Pop into out (frameSize * numFrames samples). Fills remainder with silence. Returns available frames.
    size_t pop(float* out, size_t numFrames);

    size_t availableFrames() const;
    size_t freeFrames() const;
    uint64_t overruns() const { return overruns_.load(); }
    uint64_t underruns() const { return underruns_.load(); }
    void reset();

private:
    size_t capacityFrames_;
    size_t frameSize_;
    std::vector<float> buffer_;
    std::atomic<size_t> writePos_{0};
    std::atomic<size_t> readPos_{0};
    std::atomic<size_t> size_{0};
    std::atomic<uint64_t> overruns_{0};
    std::atomic<uint64_t> underruns_{0};
};
