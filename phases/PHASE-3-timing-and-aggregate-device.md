# Phase 3: Timing and Private Aggregate Device

> PLAN.md chapters: 8, 11, 19, 20, 21, 24, 26.
> Prerequisite: Phase 2 DONE - timestamped render reference + raw mic both stable, no self-reference.
> Status: NOT STARTED

## Objective

Unify the two independent capture streams (raw mic + system tap) onto a single clock domain with bounded drift, timestamped ring buffers, and an exact 10 ms / 480-sample frame assembler. This phase is the synchronization foundation that makes AEC3's delay estimator meaningful. Without it, render and mic frames slowly slide apart and cancellation collapses.

Follows PLAN chapter 11 ("Clocking and synchronization") - the chapter the spec calls "one of the most important parts."

## Step 1: Understand the clock problem

Two Core Audio streams from different devices almost never share the same hardware clock:

- The tap's clock is derived from the physical output device (speaker DAC).
- The mic's clock is derived from the microphone device (ADC).
- Even at the same nominal 48 kHz, they drift by tens of ppm. Over minutes, frames accumulate skew.
- Throwing away `AudioTimeStamp` and assuming "one render callback = one mic callback" guarantees drift.

Additional contributors: OS buffering, speaker/mic latency, propagation delay, resampler delay. A single fixed offset (e.g., 80 ms) is explicitly forbidden as the full solution (PLAN 11.4).

## Step 2: Private aggregate device (primary strategy, PLAN 11.2)

Apple documents that an aggregate device synchronizes clocks of its subdevices and subtaps during I/O. Prefer this over custom drift correction.

### AggregateDeviceManager.swift

```swift
final class AggregateDeviceManager {
    private var aggregateID: AudioDeviceID?

    /// Creates a private aggregate containing:
    ///   - selected mic as subdevice
    ///   - system tap as subtap
    func createAggregate(micID: AudioDeviceID, tapID: AudioTapID) throws

    /// Destroys the aggregate and releases the TAP/subdevice bindings
    func destroy()

    /// Which constituent is the clock master.
    /// Start with tap (output-related) as master, mic as drift-compensated,
    /// but support switching - do not hard-code without measurement (PLAN 11.2).
    var clockSource: ClockSource { get set } // .tap or .mic

    var aggregateDeviceID: AudioDeviceID? { get }
}
```

Pseudocode (verify exact keys in the SDK - use Apple's `AudioHardwareAggregateDevice` docs):

```swift
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Anti-Bleed Aggregate (private)",
    kAudioAggregateDeviceUIDKey: "com.antibleed.aggregate.\(UUID().uuidString)",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false, // not stacked; we drive one logical device
    kAudioAggregateDeviceTapAutoStartKey: true,
]
// Add subdevice: selected mic
// Add subtap: the process tap from Phase 2
// Designate clock source
var aggID: AudioDeviceID = 0
AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
```

Research tasks (do on the Mac, record in `Docs/Architecture.md`):

1. Does the aggregate reliably drift-compensate both constituents on this OS version?
2. Which constituent should be the clock master for lowest jitter? Test both (`tap=master` vs `mic=master`) with a 30-minute run and compare `bufferSkew` and `delayStddev`.
3. How does the aggregate behave when the selected output or mic is unplugged mid-session?

If the aggregate approach fails on a specific OS/device combination, fall back to independent streams with timestamp alignment (Step 3) and a software drift estimator - but keep the aggregate as the default.

## Step 3: Timestamp layer (always required, even with aggregate)

Preserve and propagate Core Audio timestamps through the entire pipeline. Every block entering the pipeline carries (PLAN 11.1):

```swift
struct AudioBlock {
    var samples: [Float]
    var sampleRate: Double
    var channels: UInt32
    var hostTime: UInt64          // mHostTime (mach_absolute_time)
    var sampleTime: Float64       // mSampleTime
    var rateScalar: Float64       // mRateScalar
    var source: Source            // .render or .mic
    var sequenceNumber: UInt64
}
```

Rules:

- Capture `mHostTime`, `mSampleTime`, `mRateScalar` in the tap/mic callbacks and store them alongside the samples in the ring items. Never drop timing at the callback boundary.
- Convert `hostTime` to a common timebase for comparison using `AudioConvertHostTimeToNanos` or `mach_absolute_time` delta logic.
- Each ring item preserves enough metadata to align frames downstream.

## Step 4: Ring buffers (bounded, real-time safe)

Reuse `DSP/RingBuffer` from Phase 0. In Phase 3 it is instantiated as:

```text
RenderReferenceRing   // far-end, from tap
RawMicRing            // near-end, from mic
ProcessedMicRing      // after AEC (Phase 5 fills this; Phase 3 stub allocates it)
VirtualWriterRing     // to hidden writer (Phase 8 fills this; Phase 3 stub allocates it)
```

Requirements (PLAN 11.3):

- Preallocated, no malloc/free on the real-time thread.
- No unbounded queues; fixed capacity chosen for ~500 ms - 1 s worst-case drift (e.g., 100 frames at 10 ms).
- No blocking mutex on Core Audio callbacks. Lock-free SPSC or try-lock with drop policy.
- Defined overflow: drop oldest stale data, increment `overruns`.
- Defined underflow: output silence, increment `underruns`.
- Telemetry counters for overruns/underruns, current depth, high-water mark.

## Step 5: Frame alignment - layered approach (PLAN 11.4)

### Layer 1 - Aggregate clock sync

Handled by Step 2 where available.

### Layer 2 - Timestamp alignment

The DSP worker pulls timestamp-aligned blocks:

```swift
final class AudioSynchronizer {
    func pullAlignedFrames() -> (render: AudioFrame, mic: AudioFrame)?
    // Strategy:
    // 1. Peek head of RenderReferenceRing and RawMicRing.
    // 2. Compare hostTime (converted to nanos) within a window (e.g., +/- 5 ms).
    // 3. If skew exceeds threshold, drop the older side's stale frames.
    // 4. Return a pair whose hostTimes are closest and within tolerance.
    // 5. Track bufferSkew = renderHostTime - micHostTime (filtered).
}
```

- Do not busy-wait for the perfect pair. If one ring is empty, return `nil` and let the caller handle underflow (silence or hold).
- Track `bufferSkew`, `underruns`, `overruns`, and `clockDriftPPM` for diagnostics.

### Layer 3 - AEC3 delay estimator (Phase 4+)

The external synchronizer only provides coarse alignment (a few ms). AEC3 refines the acoustic delay internally. This phase prepares the plumbing so AEC3 receives already-coarsely-aligned 10 ms pairs.

### Layer 4 - Monitoring

Continuously track and log (throttled, not per-frame):

```text
current AEC delay estimate (when AEC exists)
delay median / stddev
buffer skew (render - mic hostTime delta)
underruns / overruns per ring
clock drift (ppm, inferred from skew slope)
queue depths
```

A fixed delay is never the solution. The median/stddev metrics are the observable that proves sync is bounded.

## Step 6: DSP worker and exact 10 ms framing

Callbacks write variable-size blocks into the rings. A dedicated high-priority DSP thread assembles exact 480-sample frames:

```swift
final class AntiBleedPipeline {
    private let renderRing: RingBuffer<AudioBlock>
    private let micRing: RingBuffer<AudioBlock>
    private let synchronizer: AudioSynchronizer
    private let frameAssembler: FrameAssembler // accumulates to 480 boundaries

    func startDSPThread() // Thread QoS: .userInitiated or .utility with high priority; NOT main thread
    func stopDSPThread()
}
```

Pseudocode for the worker loop:

```text
while running {
    guard let (renderBlock, micBlock) = synchronizer.pullAlignedFrames() else {
        // underflow: increment counter, sleep ~1 ms, continue
        continue
    }
    let renderFrames = frameAssembler.pushRender(renderBlock) // may emit 0..N frames of 480
    let micFrames    = frameAssembler.pushMic(micBlock)
    let count = min(renderFrames.count, micFrames.count)
    for i in 0..<count {
        let r = renderFrames[i] // 480 Float32 mono @ 48 kHz
        let m = micFrames[i]
        // Phase 3: no AEC yet - just verify alignment and forward m as-is to a debug sink
        // Phase 5: r -> ProcessReverseStream, m -> ProcessStream
        debugSink.write(m)
        updateMetrics(render: r, mic: m)
    }
}
```

- The worker is NOT the Core Audio callback thread and NOT the UI thread.
- No allocation in the hot loop beyond preallocated frame arrays.
- Resampling (if any) preserves continuous state; its delay is included in `hostTime` propagation.

## Step 7: Handling device/route changes

On any Core Audio device change (output switch, mic switch, sample-rate change, device removed):

```text
1. Immediately treat pipeline as BYPASS (Phase 7 formalizes this; Phase 3 does raw passthrough).
2. Tear down old tap and aggregate.
3. Create tap + aggregate for the new physical devices.
4. Reset ring buffers (drop stale data, reset sequence numbers).
5. Reset synchronizer state (clear skew filter, delay estimates).
6. Re-enter probing (Phase 5+ resets AEC here; Phase 3 just re-primes sync).
```

Never continue applying old timing assumptions to a new device pair.

## Step 8: Tests

### Unit tests

```text
RingBufferSyncTests:
  - SPSC push/pop with AudioBlock metadata preserved
  - overflow drops oldest, underflow returns silence, counters correct
  - wrap-around at capacity

TimestampAlignmentTests:
  - two streams with known skew -> synchronizer pairs the closest hosts
  - stale-frame drop when skew > threshold
  - empty ring returns nil without blocking

FrameAssemblerTests (both streams):
  - variable input sizes -> exact 480 outputs
  - remainder buffering, sequence monotonic, hostTime interpolated

DriftSimulationTests:
  - simulate 50 ppm drift (render 48k, mic 48k * 1.00005) for 60 s simulated
  - assert bufferSkew stays bounded and does not grow linearly (aggregate or soft correction)
  - assert underruns/overruns stay below threshold
```

### Hardware stability test (on the Mac, 30-60 minutes - PLAN 32 Phase 3 acceptance)

```text
1. Start app with MacBook mic + MacBook speakers.
2. Play continuous audio (YouTube/music) for 30-60 minutes.
3. Speak occasionally.
4. Monitor diagnostics every 5 minutes:
     Render queue depth, Mic queue depth, bufferSkew, underruns, overruns, drift.
   Criteria:
     - Queue depths do NOT steadily grow (drift compensated).
     - bufferSkew stays within +/- 10 ms.
     - No periodic frame slips (audible clicks or depth sawtooth).
     - Underruns < 1 per minute during normal load.
5. Repeat once with clockSource = .tap and once with .mic; record which is better.
```

The 30-60 minute run is a release gate for this phase. Do not skip it.

## Acceptance criteria

- [ ] Private aggregate device creates successfully with mic subdevice + tap subtap; `aggregateDeviceID` resolves; destroying it cleanly releases both constituents without leaking.
- [ ] Both `ClockSource` options (tap-master and mic-master) are selectable and survive a device switch without crash.
- [ ] `AudioSynchronizer` pairs render/mic blocks by `hostTime` within tolerance; stale-frame drop works; drift metrics are exposed in DiagnosticsView.
- [ ] DSP worker assembles exact 480-sample frames from variable-size callbacks for both streams; `FrameAssemblerTests` green.
- [ ] 30-60 minute stability run shows bounded queue depths, bounded `bufferSkew`, and no growing overrun/underrun - recorded in `Tests/OfflineFixtures/stability-*.log` or `Docs/Testing.md` with real numbers.
- [ ] Route change (output or mic switch) tears down and rebuilds the aggregate within 1 s without crash; old timing state is reset.
- [ ] `macos-build.yml` green; no per-frame logging, no malloc in callbacks, no UI work on audio threads.
- [ ] `Docs/Architecture.md` updated with aggregate lifecycle diagram and the measured master-clock choice.

## Pitfalls

- Hard-coding the clock source without measurement. Always measure both options; the docs say "do not hard-code a clock-source assumption without measurement."
- Discarding `AudioTimeStamp` at the callback and re-stamping with `Date.now()` - destroys the information AEC3 needs.
- Using an unbounded queue "because drift might be large" - guarantees growing latency. Bounded rings with defined drop policy are required.
- Testing sync for only 10 seconds. Drift takes minutes to manifest; the 30-60 minute run is not optional.

## Next phase gate

Phase 4 may start only when timestamped sync is bounded for at least 30 minutes on real hardware for both clock-source options, with numbers recorded. No synthetic AEC until sync is proven.
