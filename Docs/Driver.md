# Anti-Bleed_mic: Driver Notes

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 15, 16, 27, 36, 37.
> Status: stub - filled in Phase 8-11.

## 1. Choice

Core Audio Audio Server Plug-in (`AntiBleed.driver`), not AudioDriverKit. Apple documents the plug-in as the preferred mechanism for virtual devices; AudioDriverKit is for physical drivers (D-004).

## 2. Topology (D-005)

```text
Anti-Bleed app -> Anti-Bleed_internal_writer [hidden, output, UID com.antibleed.writer]
                      |
               shared driver SPSC ring (bounded, lock-free)
                      |
               Anti-Bleed_mic [visible, input, UID com.antibleed.mic] -> Discord
```

- Visible: input-only, `isHidden=false`.
- Hidden writer: output-only, `kAudioDevicePropertyIsHidden=true`, discovered by UID.
- Install path: `/Library/Audio/Plug-Ins/HAL/AntiBleed.driver`.

## 3. Ring policy

- Bounded, preallocated, no malloc in I/O proc, no blocking lock.
- Underflow (app not writing): output **silence**, never replay or uninitialized memory (PLAN 15.3).
- Overrun: drop oldest stale data, deliver newest (PLAN 15.4).
- Counters: `underruns`, `overruns`, high-water depth - readable via driver property for Diagnostics.

## 4. Self-reference avoidance

The system tap (Phase 2) must exclude the writer UID so driver writes never re-enter the AEC reference. Verify with the loopback tone test (write a tone only via the writer and assert it does not appear in the tap capture).

## 5. BlackHole (Phase 6 only)

BlackHole 2ch was the Phase 6 scaffold before the native driver. GPL-3.0 - never copy its source into this repo's proprietary release without resolving licensing (PLAN 16.1, D-010). As of Phase 9, BlackHole is not a runtime dependency.

## 6. Installation (dev vs release)

- Dev: `Scripts/install-driver.sh` / `uninstall-driver.sh` - copy to HAL, chown root:wheel, restart coreaudiod, verify device appears.
- Release: signed `.pkg` containing `AntiBleed.app` + `AntiBleed.driver`, with postinstall verification (Phase 11, `Docs/Distribution.md`).

## 7. Log - fill after each driver change

| Date | Change | Writer->mic loop fidelity | Underflow silence | Overrun policy | Latency | Notes |
|------|--------|---------------------------|-------------------|----------------|---------|-------|
|      |        |                           |                   |                |         |       |
