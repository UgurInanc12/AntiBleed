# AntiBleedDriver

Audio Server Plug-in for Anti-Bleed_mic (Phase 8).

- Visible input: `Anti-Bleed_mic` (UID `com.antibleed.mic`, input-only)
- Hidden writer: `Anti-Bleed_internal_writer` (UID `com.antibleed.writer`, output-only, `kAudioDevicePropertyIsHidden`)
- Shared ring: `SharedRingBuffer/` (bounded SPSC, underflow silence, overrun drop oldest)

Build on Mac via Xcode target or CMake. Install to `/Library/Audio/Plug-Ins/HAL/AntiBleed.driver`.
See `phases/PHASE-8-custom-virtual-driver.md`.
