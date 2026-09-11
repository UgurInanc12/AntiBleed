#include "abm_ring.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t frames;
    uint64_t host_time_ns;
    double sample_time;
    double rate_scalar;
} slot_meta_t;

struct abm_ring {
    uint32_t slots;
    uint32_t max_frames;
    float* mic;      // slots * max_frames
    float* render;   // slots * max_frames
    slot_meta_t* meta;
    float* read_mic;
    float* read_render;
    atomic_flag access;
    _Atomic uint32_t write_idx; // owned by producer
    _Atomic uint32_t read_idx;  // owned by consumer
    _Atomic uint32_t count;
    _Atomic uint64_t overruns;
};

abm_ring_t* abm_ring_create(uint32_t slots, uint32_t max_frames) {
    if (slots < 2 || max_frames == 0) return NULL;
    abm_ring_t* r = (abm_ring_t*)calloc(1, sizeof(abm_ring_t));
    if (!r) return NULL;
    atomic_flag_clear(&r->access);
    r->slots = slots;
    r->max_frames = max_frames;
    r->mic = (float*)calloc((size_t)slots * max_frames, sizeof(float));
    r->render = (float*)calloc((size_t)slots * max_frames, sizeof(float));
    r->meta = (slot_meta_t*)calloc(slots, sizeof(slot_meta_t));
    r->read_mic = (float*)calloc(max_frames, sizeof(float));
    r->read_render = (float*)calloc(max_frames, sizeof(float));
    if (!r->mic || !r->render || !r->meta || !r->read_mic || !r->read_render) {
        abm_ring_destroy(r);
        return NULL;
    }
    atomic_init(&r->write_idx, 0);
    atomic_init(&r->read_idx, 0);
    atomic_init(&r->count, 0);
    atomic_init(&r->overruns, 0);
    return r;
}

void abm_ring_destroy(abm_ring_t* r) {
    if (!r) return;
    free(r->mic);
    free(r->render);
    free(r->meta);
    free(r->read_mic);
    free(r->read_render);
    free(r);
}

int abm_ring_push(abm_ring_t* r, const float* mic, const float* render, uint32_t frames,
                  uint64_t host_time_ns, double sample_time, double rate_scalar) {
    if (!r || frames == 0 || frames > r->max_frames) return -1;
    // Never wait in an audio callback. A concurrent copy owns the storage.
    if (atomic_flag_test_and_set_explicit(&r->access, memory_order_acquire)) {
        atomic_fetch_add_explicit(&r->overruns, 1, memory_order_relaxed);
        return 1;
    }
    int dropped = 0;
    // Only touch the shared cursors/storage while holding the non-waiting gate.
    if (atomic_load_explicit(&r->count, memory_order_acquire) == r->slots) {
        uint32_t ri = atomic_load_explicit(&r->read_idx, memory_order_relaxed);
        atomic_store_explicit(&r->read_idx, (ri + 1) % r->slots, memory_order_release);
        atomic_fetch_sub_explicit(&r->count, 1, memory_order_acq_rel);
        atomic_fetch_add_explicit(&r->overruns, 1, memory_order_relaxed);
        dropped = 1;
    }
    uint32_t wi = atomic_load_explicit(&r->write_idx, memory_order_relaxed);
    float* m = r->mic + (size_t)wi * r->max_frames;
    float* v = r->render + (size_t)wi * r->max_frames;
    if (mic) memcpy(m, mic, frames * sizeof(float)); else memset(m, 0, frames * sizeof(float));
    if (render) memcpy(v, render, frames * sizeof(float)); else memset(v, 0, frames * sizeof(float));
    r->meta[wi].frames = frames;
    r->meta[wi].host_time_ns = host_time_ns;
    r->meta[wi].sample_time = sample_time;
    r->meta[wi].rate_scalar = rate_scalar;
    atomic_store_explicit(&r->write_idx, (wi + 1) % r->slots, memory_order_relaxed);
    atomic_fetch_add_explicit(&r->count, 1, memory_order_release);
    atomic_flag_clear_explicit(&r->access, memory_order_release);
    return dropped;
}

bool abm_ring_pop(abm_ring_t* r, abm_block_view_t* view) {
    if (!r || !view) return false;
    if (atomic_flag_test_and_set_explicit(&r->access, memory_order_acquire)) return false;
    if (atomic_load_explicit(&r->count, memory_order_acquire) == 0) {
        atomic_flag_clear_explicit(&r->access, memory_order_release);
        return false;
    }
    uint32_t ri = atomic_load_explicit(&r->read_idx, memory_order_acquire);
    // The returned view belongs to the consumer until its next pop.
    memcpy(r->read_mic, r->mic + (size_t)ri * r->max_frames, r->meta[ri].frames * sizeof(float));
    memcpy(r->read_render, r->render + (size_t)ri * r->max_frames, r->meta[ri].frames * sizeof(float));
    view->mic = r->read_mic;
    view->render = r->read_render;
    view->frames = r->meta[ri].frames;
    view->host_time_ns = r->meta[ri].host_time_ns;
    view->sample_time = r->meta[ri].sample_time;
    view->rate_scalar = r->meta[ri].rate_scalar;
    atomic_store_explicit(&r->read_idx, (ri + 1) % r->slots, memory_order_release);
    atomic_fetch_sub_explicit(&r->count, 1, memory_order_acq_rel);
    atomic_flag_clear_explicit(&r->access, memory_order_release);
    return true;
}

uint32_t abm_ring_available(const abm_ring_t* r) { return r ? atomic_load(&((abm_ring_t*)r)->count) : 0; }
uint64_t abm_ring_overruns(const abm_ring_t* r) { return r ? atomic_load(&((abm_ring_t*)r)->overruns) : 0; }
uint32_t abm_ring_max_frames(const abm_ring_t* r) { return r ? r->max_frames : 0; }

void abm_ring_reset(abm_ring_t* r) {
    if (!r) return;
    atomic_store(&r->write_idx, 0);
    atomic_store(&r->read_idx, 0);
    atomic_store(&r->count, 0);
    atomic_store(&r->overruns, 0);
}

// ---------------------------------------------------------------- FIFO

struct abm_fifo {
    uint32_t capacity;
    float* buf;
    atomic_flag access;
    _Atomic uint32_t write_pos;
    _Atomic uint32_t read_pos;
    _Atomic uint32_t size;
    _Atomic uint64_t overruns;
    _Atomic uint64_t underruns;
};

abm_fifo_t* abm_fifo_create(uint32_t capacity_samples) {
    if (capacity_samples == 0) return NULL;
    abm_fifo_t* f = (abm_fifo_t*)calloc(1, sizeof(abm_fifo_t));
    if (!f) return NULL;
    atomic_flag_clear(&f->access);
    f->capacity = capacity_samples;
    f->buf = (float*)calloc(capacity_samples, sizeof(float));
    if (!f->buf) { free(f); return NULL; }
    return f;
}

void abm_fifo_destroy(abm_fifo_t* f) {
    if (!f) return;
    free(f->buf);
    free(f);
}

uint32_t abm_fifo_push(abm_fifo_t* f, const float* data, uint32_t count) {
    if (!f || !data || count == 0) return 0;
    if (atomic_flag_test_and_set_explicit(&f->access, memory_order_acquire)) {
        atomic_fetch_add_explicit(&f->overruns, count, memory_order_relaxed);
        return count;
    }
    uint32_t dropped = 0;
    if (count > f->capacity) {
        data += count - f->capacity;
        dropped += count - f->capacity;
        count = f->capacity;
    }
    uint32_t size = atomic_load_explicit(&f->size, memory_order_acquire);
    if (size + count > f->capacity) {
        uint32_t excess = size + count - f->capacity;
        uint32_t rp = atomic_load_explicit(&f->read_pos, memory_order_relaxed);
        atomic_store_explicit(&f->read_pos, (rp + excess) % f->capacity, memory_order_release);
        atomic_fetch_sub_explicit(&f->size, excess, memory_order_acq_rel);
        dropped += excess;
    }
    uint32_t wp = atomic_load_explicit(&f->write_pos, memory_order_relaxed);
    uint32_t first = f->capacity - wp;
    if (first > count) first = count;
    memcpy(f->buf + wp, data, first * sizeof(float));
    if (count > first) memcpy(f->buf, data + first, (count - first) * sizeof(float));
    atomic_store_explicit(&f->write_pos, (wp + count) % f->capacity, memory_order_relaxed);
    atomic_fetch_add_explicit(&f->size, count, memory_order_release);
    atomic_fetch_add_explicit(&f->overruns, dropped, memory_order_relaxed);
    atomic_flag_clear_explicit(&f->access, memory_order_release);
    return dropped;
}

uint32_t abm_fifo_pop(abm_fifo_t* f, float* out, uint32_t count) {
    if (!f || !out || count == 0) return 0;
    if (atomic_flag_test_and_set_explicit(&f->access, memory_order_acquire)) {
        memset(out, 0, count * sizeof(float));
        atomic_fetch_add_explicit(&f->underruns, count, memory_order_relaxed);
        return 0;
    }
    uint32_t size = atomic_load_explicit(&f->size, memory_order_acquire);
    uint32_t avail = size < count ? size : count;
    uint32_t rp = atomic_load_explicit(&f->read_pos, memory_order_relaxed);
    uint32_t first = f->capacity - rp;
    if (first > avail) first = avail;
    memcpy(out, f->buf + rp, first * sizeof(float));
    if (avail > first) memcpy(out + first, f->buf, (avail - first) * sizeof(float));
    if (avail < count) {
        memset(out + avail, 0, (count - avail) * sizeof(float));
        atomic_fetch_add_explicit(&f->underruns, count - avail, memory_order_relaxed);
    }
    atomic_store_explicit(&f->read_pos, (rp + avail) % f->capacity, memory_order_release);
    atomic_fetch_sub_explicit(&f->size, avail, memory_order_acq_rel);
    atomic_flag_clear_explicit(&f->access, memory_order_release);
    return avail;
}

uint32_t abm_fifo_available(const abm_fifo_t* f) { return f ? atomic_load(&((abm_fifo_t*)f)->size) : 0; }
uint64_t abm_fifo_overruns(const abm_fifo_t* f) { return f ? atomic_load(&((abm_fifo_t*)f)->overruns) : 0; }
uint64_t abm_fifo_underruns(const abm_fifo_t* f) { return f ? atomic_load(&((abm_fifo_t*)f)->underruns) : 0; }

bool abm_fifo_try_reset(abm_fifo_t* f) {
    if (!f || atomic_flag_test_and_set_explicit(&f->access, memory_order_acquire)) return false;
    atomic_store(&f->write_pos, 0);
    atomic_store(&f->read_pos, 0);
    atomic_store(&f->size, 0);
    atomic_store(&f->overruns, 0);
    atomic_store(&f->underruns, 0);
    atomic_flag_clear_explicit(&f->access, memory_order_release);
    return true;
}

void abm_fifo_reset(abm_fifo_t* f) { (void)abm_fifo_try_reset(f); }
