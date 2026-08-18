# Anti-Bleed_mic: Permissions

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 10, 26, 27.
> Status: stub - filled in Phase 1-2, finalized in Phase 10.

## 1. Required Info.plist keys

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Anti-Bleed needs microphone access to create the cleaned virtual microphone.</string>

<key>NSAudioCaptureUsageDescription</key>
<string>Anti-Bleed reads the audio sent to your output device locally so it can remove speaker bleed from your microphone.</string>
```

- Phase 1 adds only the first key; Phase 2 adds the second.
- Do not request both in the same flow - handle them independently.

## 2. Behavior

| Permission | If granted | If denied |
|------------|------------|-----------|
| Microphone | Capture runs, raw frames available | No crash, output silence, actionable error with button to System Settings -> Privacy & Security -> Microphone |
| System audio (tap) | Render reference available, AEC can run | Raw-mic bypass, banner "AEC unavailable - system audio reference lost", raw mic keeps working |

## 3. Privacy guarantees (shown on first launch and in Settings)

- All processing stays on the Mac (PLAN 38).
- No cloud API, no speech-to-text, no analytics containing audio, no hidden recording, no upload.
- Debug WAV dumps: disabled by default, developer/test opt-in only, visible indicator, defined deletion path.

## 4. Implementation notes

- `Permissions.swift` is the single source for permission state, with `@Published` properties and `MainActor` updates.
- Never spam the system prompt; call `requestRecordPermission` only on explicit user action.
- Log state transitions once per transition, never per frame.

## 5. Log - fill after each permission-matrix test

| Date | macOS | Mic denied | System audio denied | Both denied | Both granted | Notes |
|------|-------|------------|---------------------|-------------|--------------|-------|
|      |       |            |                     |             |              |       |
