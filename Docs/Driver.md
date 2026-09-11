# Anti-Bleed_mic: Driver Notes

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 15, 16, 27, 36, 37.

## 1. Choice

Core Audio Audio Server Plug-in (`AntiBleed.driver`), not AudioDriverKit (D-004). Implemented in
plain C against `<CoreAudio/AudioServerPlugIn.h>`: `AntiBleedDriver/Driver/AntiBleedDriver.c`.
No BlackHole (GPL) code is used (D-010).

## 2. Topology (D-005)

```text
Anti-Bleed app -> Anti-Bleed_internal_writer [hidden, output, UID com.antibleed.writer]
                      |
               driver ring (500 ms, non-waiting atomic gate)
                      |
               Anti-Bleed_mic [visible, input, UID com.antibleed.mic] -> Discord
```

Object IDs: plug-in 1, mic device 2, mic stream 3, writer device 4, writer stream 5.
Both devices: 48 kHz Float32 mono, fixed; `kAudioDevicePropertyNominalSampleRate` only accepts 48000.
Writer: `kAudioDevicePropertyIsHidden = 1`, `CanBeDefaultDevice = 0`. Mic: `CanBeDefaultDevice = 1`.

## 3. IO

- Writer `WriteMix` -> `abm_fifo_push`. Mic `ReadInput` -> `abm_fifo_pop`; underflow fills zeros and counts.
- The driver and app use the same tested C FIFO. Overflow drops oldest audio; concurrent access rejects incoming writes or returns silence on reads, never waits or spins. Both are counted.
- This is bounded non-waiting access, not a lossless lock-free queue. Measure contention and audible gaps on the Mac before release.
- If the writer has no running IO (app quit or crashed) the mic reads pure silence: no stale audio.
- Zero timestamp: software clock, 4800-frame period, seed bumps on each StartIO from idle.
- Custom read-only property `'abrs'` on the mic device: a CFString `"underruns,overruns"` for Diagnostics.

## 4. Build and install (Mac)

```text
cmake -S AntiBleedDriver -B build/driver -DCMAKE_BUILD_TYPE=Release && cmake --build build/driver
sudo Scripts/install-driver.sh            # copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod, verifies
sudo Scripts/uninstall-driver.sh
```

`Info.plist` registers factory `5C1A3F0E-2B7D-4E8A-9C61-7A4D2E9B3F10` -> `AntiBleedDriver_Create` for `kAudioServerPlugInTypeUUID`.

## 5. Open Mac gates

- First load under coreaudiod (property table completeness is verified only by the HAL itself)
- Measure writer -> mic latency (ring depth target 2-3 frames while the app writes steadily)
- Verify `Anti-Bleed_internal_writer` does not appear in System Settings or Discord pickers
