#include "SharedRingBuffer.hpp"
#include <cstring>
#include <algorithm>

// SPSC contract: exactly one producer thread calls push(), exactly one consumer
// thread calls pop(). size_ is the only field both sides modify, so it is only
// ever changed with fetch_add/fetch_sub (never a plain store of a stale value).
// The overflow path (producer advances readPos_) is the one place the producer
// touches consumer state; the consumer tolerates it because it re-reads readPos_
// and size_ atomically on every pop.

SharedRingBuffer::SharedRingBuffer(size_t capacityFrames, size_t frameSize)
    : capacityFrames_(capacityFrames), frameSize_(frameSize), buffer_(capacityFrames * frameSize, 0.0f) {}

size_t SharedRingBuffer::push(const float* data, size_t numFrames) {
    if (!data || numFrames == 0) return 0;
    if (numFrames > capacityFrames_) {
        data += (numFrames - capacityFrames_) * frameSize_;
        numFrames = capacityFrames_;
    }
    size_t dropped = 0;
    size_t sz = size_.load(std::memory_order_acquire);
    if (sz + numFrames > capacityFrames_) {
        dropped = sz + numFrames - capacityFrames_;
        size_t rp = readPos_.load(std::memory_order_relaxed);
        readPos_.store((rp + dropped * frameSize_) % buffer_.size(), std::memory_order_release);
        size_.fetch_sub(dropped, std::memory_order_acq_rel);
        overruns_.fetch_add(dropped, std::memory_order_relaxed);
    }
    size_t wp = writePos_.load(std::memory_order_relaxed);
    size_t totalSamples = numFrames * frameSize_;
    size_t first = std::min(totalSamples, buffer_.size() - wp);
    std::memcpy(buffer_.data() + wp, data, first * sizeof(float));
    if (totalSamples > first) std::memcpy(buffer_.data(), data + first, (totalSamples - first) * sizeof(float));
    writePos_.store((wp + totalSamples) % buffer_.size(), std::memory_order_relaxed);
    size_.fetch_add(numFrames, std::memory_order_release);
    return dropped;
}

size_t SharedRingBuffer::pop(float* out, size_t numFrames) {
    if (!out || numFrames == 0) return 0;
    size_t sz = size_.load(std::memory_order_acquire);
    size_t avail = std::min(sz, numFrames);
    size_t rp = readPos_.load(std::memory_order_acquire);
    size_t availSamples = avail * frameSize_;
    size_t first = std::min(availSamples, buffer_.size() - rp);
    std::memcpy(out, buffer_.data() + rp, first * sizeof(float));
    if (availSamples > first) std::memcpy(out + first, buffer_.data(), (availSamples - first) * sizeof(float));
    size_t remain = (numFrames - avail) * frameSize_;
    if (remain) {
        std::memset(out + availSamples, 0, remain * sizeof(float)); // silence, never replay
        underruns_.fetch_add(numFrames - avail, std::memory_order_relaxed);
    }
    readPos_.store((rp + availSamples) % buffer_.size(), std::memory_order_release);
    if (avail) size_.fetch_sub(avail, std::memory_order_acq_rel);
    return avail;
}

size_t SharedRingBuffer::availableFrames() const { return size_.load(std::memory_order_acquire); }
size_t SharedRingBuffer::freeFrames() const { return capacityFrames_ - availableFrames(); }
void SharedRingBuffer::reset() {
    writePos_.store(0); readPos_.store(0); size_.store(0);
    overruns_.store(0); underruns_.store(0);
    std::fill(buffer_.begin(), buffer_.end(), 0.0f);
}
