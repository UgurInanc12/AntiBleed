#include "SharedRingBuffer.hpp"
#include <cstring>
#include <algorithm>

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
        readPos_.store((readPos_.load() + dropped * frameSize_) % buffer_.size(), std::memory_order_release);
        overruns_.fetch_add(dropped);
        size_.store(capacityFrames_ - numFrames, std::memory_order_release);
    }
    size_t wp = writePos_.load();
    size_t totalSamples = numFrames * frameSize_;
    for (size_t i = 0; i < totalSamples; ++i) {
        buffer_[(wp + i) % buffer_.size()] = data[i];
    }
    writePos_.store((wp + totalSamples) % buffer_.size(), std::memory_order_release);
    if (dropped) size_.store(capacityFrames_, std::memory_order_release);
    else size_.store(sz + numFrames, std::memory_order_release);
    return dropped;
}

size_t SharedRingBuffer::pop(float* out, size_t numFrames) {
    if (!out || numFrames == 0) return 0;
    size_t sz = size_.load(std::memory_order_acquire);
    size_t avail = std::min(sz, numFrames);
    size_t rp = readPos_.load();
    size_t availSamples = avail * frameSize_;
    for (size_t i = 0; i < availSamples; ++i) out[i] = buffer_[(rp + i) % buffer_.size()];
    size_t remain = (numFrames - avail) * frameSize_;
    if (remain) {
        std::memset(out + availSamples, 0, remain * sizeof(float));
        underruns_.fetch_add(numFrames - avail);
    }
    readPos_.store((rp + availSamples) % buffer_.size(), std::memory_order_release);
    size_.store(sz - avail, std::memory_order_release);
    return avail;
}

size_t SharedRingBuffer::availableFrames() const { return size_.load(); }
size_t SharedRingBuffer::freeFrames() const { return capacityFrames_ - availableFrames(); }
void SharedRingBuffer::reset() {
    writePos_.store(0); readPos_.store(0); size_.store(0);
    overruns_.store(0); underruns_.store(0);
    std::fill(buffer_.begin(), buffer_.end(), 0.0f);
}
