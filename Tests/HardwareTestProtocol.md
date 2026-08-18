# Hardware Test Protocol

> PLAN chapters 29, 30, 40. Run on a real Mac with speakers and microphone.
> Record three synchronized tracks per test: raw mic, render reference, cleaned output.

## Setup

- Mac with macOS 14.2+, Apple Silicon preferred
- Audio MIDI Setup: verify 48 kHz where possible
- Anti-Bleed running with pipeline ACTIVE or BYPASS as appropriate
- Debug dump enabled (three-track WAV) for measurement

## Matrix

### Speaker volume sweep
25% / 50% / 75% / high non-clipping - each with: male speech, female speech, music, game audio, abrupt SFX

### Near-end states
Silent / continuous speech / intermittent speech / double-talk / keyboard / room noise

### Physical changes
Lid angle / desk move / user position / room switch (if available)

### Route changes
MacBook speakers <-> wired headphones <-> Bluetooth headphones <-> external speakers <-> HDMI/monitor <-> mute/unmute

All tests verify: mic selection persists, tap captures, sync bounded, AEC stats healthy, output correct per state machine.

## Acceptance

- Speaker bleed: >=20 dB echo reduction representative (stretch 30 dB where acoustics allow)
- Double-talk: user speech intelligible
- Headphones/no-coupling: output approx raw mic, no inverse render
- Latency: <50 ms (stretch <30 ms)
- No clicks, no growing queues, no periodic glitches in 30-60 min run
