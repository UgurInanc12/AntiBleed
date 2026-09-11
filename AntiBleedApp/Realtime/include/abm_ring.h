// Real-time safe single-producer/single-consumer block ring shared by the
// Core Audio IOProc (producer) and the DSP worker (consumer).
//
// Each slot holds one callback's worth of samples for two channels-groups
// (mic and render/tap) plus timing metadata. All memory is allocated once in
// abm_ring_create(); push/pop only touch preallocated memory and C11 atomics.
// Overflow drops the oldest slot. On concurrent access, push rejects the new
// block and pop returns empty. Neither operation waits or spins.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct abm_ring abm_ring_t;

typedef struct abm_block_view {
    const float* mic;      // mono Float32, `frames` samples
    const float* render;   // mono Float32, `frames` samples (may be all zero when no tap)
    uint32_t frames;
    uint64_t host_time_ns; // host time of the first sample
    double sample_time;
    double rate_scalar;
} abm_block_view_t;

// slots: number of callback blocks buffered (e.g. 64); max_frames: largest
// callback size accepted (e.g. 4096). Returns NULL on allocation failure.
abm_ring_t* abm_ring_create(uint32_t slots, uint32_t max_frames);
void abm_ring_destroy(abm_ring_t* ring);

// Producer side (IOProc). Copies `frames` samples of mic and render (either may
// be NULL -> zeros). Returns 1 on a dropped/rejected block, 0 on success,
// -1 for an invalid size.
int abm_ring_push(abm_ring_t* ring, const float* mic, const float* render, uint32_t frames,
                  uint64_t host_time_ns, double sample_time, double rate_scalar);

// Consumer side. Returns true and fills `view` (valid until the next pop) when a
// block is available.
bool abm_ring_pop(abm_ring_t* ring, abm_block_view_t* view);

uint32_t abm_ring_available(const abm_ring_t* ring);
uint64_t abm_ring_overruns(const abm_ring_t* ring);
uint32_t abm_ring_max_frames(const abm_ring_t* ring);
void abm_ring_reset(abm_ring_t* ring);

// Simple SPSC float FIFO for the writer path (DSP -> writer IOProc).
typedef struct abm_fifo abm_fifo_t;
abm_fifo_t* abm_fifo_create(uint32_t capacity_samples);
void abm_fifo_destroy(abm_fifo_t* fifo);
// Returns samples dropped: oldest on overflow, incoming on contention.
uint32_t abm_fifo_push(abm_fifo_t* fifo, const float* data, uint32_t count);
// Fills `out` with up to `count` samples; missing samples are zero (silence).
// Returns the number of real samples delivered; the caller counts underruns.
uint32_t abm_fifo_pop(abm_fifo_t* fifo, float* out, uint32_t count);
uint32_t abm_fifo_available(const abm_fifo_t* fifo);
uint64_t abm_fifo_overruns(const abm_fifo_t* fifo);
uint64_t abm_fifo_underruns(const abm_fifo_t* fifo);
// Reset/destroy require quiescent IO. try_reset is safe with an active reader.
void abm_fifo_reset(abm_fifo_t* fifo);
bool abm_fifo_try_reset(abm_fifo_t* fifo);

#ifdef __cplusplus
}
#endif
