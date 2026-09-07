// Ring policy tests for the driver-side ring (SharedRingBuffer) and the
// app-side realtime ring/FIFO (abm_ring.c). Runs on any OS.
//
// Policies under test (PLAN 15.3/15.4):
//   - push/pop preserves samples, including wrap-around
//   - underflow yields silence and counts underruns (never stale replay)
//   - overflow drops the OLDEST data and counts overruns
//   - SPSC concurrency smoke test: no lost/duplicated frames beyond policy
#include "SharedRingBuffer.hpp"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

static void testBasicRoundTrip() {
    SharedRingBuffer r(8, 4);
    float in[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CHECK(r.push(in, 2) == 0);
    CHECK(r.availableFrames() == 2);
    float out[8] = {0};
    CHECK(r.pop(out, 2) == 2);
    CHECK(std::memcmp(in, out, sizeof in) == 0);
    CHECK(r.availableFrames() == 0);
}

static void testUnderflowSilence() {
    SharedRingBuffer r(4, 4);
    float in[4] = {0.5f, 0.5f, 0.5f, 0.5f};
    r.push(in, 1);
    float out[12];
    std::memset(out, 0x7f, sizeof out); // poison
    CHECK(r.pop(out, 3) == 1);
    for (int i = 0; i < 4; ++i) CHECK(out[i] == 0.5f);
    for (int i = 4; i < 12; ++i) CHECK(out[i] == 0.0f); // silence, not poison, not replay
    CHECK(r.underruns() == 2);
}

static void testOverflowDropsOldest() {
    SharedRingBuffer r(3, 1);
    float a = 1, b = 2, c = 3, d = 4;
    r.push(&a, 1); r.push(&b, 1); r.push(&c, 1);
    CHECK(r.push(&d, 1) == 1);
    CHECK(r.overruns() == 1);
    float out[3];
    CHECK(r.pop(out, 3) == 3);
    CHECK(out[0] == 2 && out[1] == 3 && out[2] == 4); // oldest (1) dropped
}

static void testWrapAround() {
    // Capacity 5 frames of 1 sample; push 3 / pop 3 repeatedly so the write and
    // read positions wrap around the end of storage many times.
    SharedRingBuffer r(5, 1);
    float seq[90];
    for (int i = 0; i < 90; ++i) seq[i] = float(i);
    float out[90];
    int produced = 0, consumed = 0;
    while (produced < 90) {
        r.push(seq + produced, 3); produced += 3;
        r.pop(out + consumed, 3); consumed += 3;
    }
    CHECK(r.overruns() == 0);
    CHECK(r.underruns() == 0);
    for (int i = 0; i < produced; ++i) CHECK(out[i] == seq[i]);
}

static void testSPSCConcurrent() {
    SharedRingBuffer r(256, 1);
    const int N = 200000;
    std::atomic<bool> done{false};
    std::thread producer([&] {
        for (int i = 0; i < N; ++i) { float v = float(i); while (r.freeFrames() == 0) {} r.push(&v, 1); }
        done = true;
    });
    float last = -1; long long popped = 0; bool monotonic = true;
    while (!done || r.availableFrames() > 0) {
        float v;
        if (r.availableFrames() == 0) continue;
        r.pop(&v, 1); ++popped;
        if (v <= last) monotonic = false;
        last = v;
    }
    producer.join();
    CHECK(popped == N);
    CHECK(monotonic);
    CHECK(r.overruns() == 0);
}

int main() {
    testBasicRoundTrip();
    testUnderflowSilence();
    testOverflowDropsOldest();
    testWrapAround();
    testSPSCConcurrent();
    if (failures == 0) std::printf("SharedRingBuffer tests OK\n");
    return failures == 0 ? 0 : 1;
}
