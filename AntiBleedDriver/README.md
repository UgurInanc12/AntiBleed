# AntiBleedDriver

Core Audio AudioServerPlugIn that publishes two virtual devices sharing one ring buffer (D-004, D-005):

| Device | UID | Direction | Visible |
|---|---|---|---|
| `Anti-Bleed_mic` | `com.antibleed.mic` | input | yes (Discord, Zoom, System Settings) |
| `Anti-Bleed_internal_writer` | `com.antibleed.writer` | output | no (`kAudioDevicePropertyIsHidden`) |

Format is fixed: 48 kHz, Float32, mono. The app writes the cleaned (or raw, when bypassed)
microphone into the hidden writer; the driver copies it into a lock-free ring and vends it as
the visible input. When the app is not writing, the mic outputs silence (never stale audio).

Build on the Mac:

```bash
cmake -S AntiBleedDriver -B build/driver -DCMAKE_BUILD_TYPE=Release
cmake --build build/driver
sudo Scripts/install-driver.sh        # copies build/driver/AntiBleed.driver, restarts coreaudiod
```

The driver is plain C (`Driver/AntiBleedDriver.c`) against Apple's `AudioServerPlugIn.h` contract.
No BlackHole (GPL) source is used (D-010).

Diagnostics: the mic device exposes a custom read-only property `'abrs'` returning
a CFString `"underruns,overruns"`.
