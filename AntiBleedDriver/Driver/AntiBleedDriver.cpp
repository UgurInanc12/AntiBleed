#include "AntiBleedDriver.hpp"
#include "../SharedRingBuffer/SharedRingBuffer.hpp"
#include <cstring>

// Phase 8 stub: real HAL I/O procs are implemented on macOS.
// This file compiles on any platform and documents the intended behavior.

static SharedRingBuffer gRing(100, 480); // 100 frames ~1s

#ifdef __APPLE__
// Real implementation would provide:
// - AntiBleedDriver_Create
// - Device property handlers (kAudioDevicePropertyIsHidden, streams, formats)
// - WriterIOProc (push to gRing) and MicIOProc (pop from gRing, silence on underflow)
// See Apple sample: AudioServerPlugIn / NullAudio
extern "C" void* AntiBleedDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    return nullptr; // stub
}
#endif

// Cross-platform helpers for testing the ring policy
extern "C" size_t AntiBleedDriver_Push(const float* data, size_t frames) { return gRing.push(data, frames); }
extern "C" size_t AntiBleedDriver_Pop(float* out, size_t frames) { return gRing.pop(out, frames); }
