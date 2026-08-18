# Phase 9: Remove BlackHole Runtime Dependency

> PLAN.md chapters: 15, 16, 27, 32, 41, 43.
> Prerequisite: Phase 8 DONE - native AntiBleed.driver installed, Discord call via Anti-Bleed_mic matches BlackHole MVP quality.
> Status: NOT STARTED

## Objective

Make Anti-Bleed fully standalone on a clean Mac: no BlackHole installed, no manual Audio MIDI Setup routing, no user confusion between BlackHole and Anti-Bleed_mic. Prove the product installs and works on a machine that has never seen BlackHole.

Follows PLAN chapter 32 Phase 9 and Definition of Done items 1-15 (esp. "A clean supported Mac can install Anti-Bleed without installing BlackHole").

## Step 1: Remove BlackHole from the code path

### What to change

- Delete or gate the BlackHole-specific `VirtualMicWriter` variant from Phase 6. The writer now resolves only `com.antibleed.writer` via `AntiBleed.driver`. No fallback to `BlackHole2ch_UID` in release builds.
- Remove any `if deviceExists("BlackHole")` branches that silently route through BlackHole when the native driver is present. If both are installed during development, the app must prefer the native driver and surface the choice in Diagnostics (e.g., `Virtual output: Anti-Bleed_mic (native)`), not hide it.
- Update `DeviceManager` filtering: do not assume BlackHole exists; do not filter it out either - just ignore it. A user who still has BlackHole for other reasons should not see interference.
- Search the repo for `BlackHole` strings, `BlackHole2ch_UID`, and brew references; leave only historical mentions in `Docs/` and `phases/PHASE-6*`. No runtime reference in `AntiBleedApp/` or `AntiBleedDriver/` after this phase.

### Build flag

Introduce a compile-time flag for the dev scaffold:

```swift
#if DEV_BLACKHOLE_FALLBACK
// debug-only: allow DiagnosticsView to show BlackHole if native driver missing
#endif
```

Release builds must not contain this fallback. The installer must never install BlackHole.

## Step 2: Clean-Mac verification (the actual gate)

This phase is verified on a clean Mac state. Two options:

1. **Dedicated clean Mac or VM** that has never installed BlackHole.
2. On the dev Mac: `brew uninstall blackhole-2ch` (or run the uninstaller), `sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole*.driver`, restart Core Audio, verify `system_profiler SPAudioDataType` no longer lists BlackHole.

Then, on that clean state:

```text
1. Fresh clone -> Scripts/build-app.sh succeeds.
2. Scripts/install-driver.sh installs AntiBleed.driver.
3. Launch Anti-Bleed app.
4. Grant mic + system-audio permissions.
5. Verify Anti-Bleed_mic appears in System Settings -> Sound -> Input.
6. Verify Anti-Bleed_internal_writer does NOT appear in that picker.
7. Select Anti-Bleed_mic in Discord -> Voice & Video -> Input Device.
8. Run the Phase 6/8 Discord test matrix:
     - speakers 50% + YouTube/game audio -> remote peer hears bleed reduced
     - double-talk intelligible
     - headphones in -> bypass to raw mic (no inverse)
9. No Audio MIDI Setup manipulation required at any step.
```

Record the clean-Mac OS version, Mac model, and result in `Docs/Testing.md`.

## Step 3: Installer pre-checks (prepare for Phase 11)

Even though the full signed installer is Phase 11, Phase 9 must ensure the dev install scripts already handle the clean-Mac path:

- `Scripts/install-driver.sh`:
  - Verifies `macOS >= 14.2` before copying; fails with a clear message on older OS.
  - Copies `AntiBleed.driver` to `/Library/Audio/Plug-Ins/HAL/`, sets `root:wheel`, restarts Core Audio, verifies `Anti-Bleed_mic` appears.
  - Does not reference BlackHole at all.
- `Scripts/uninstall-driver.sh`:
  - Removes only `AntiBleed.driver`, never touches BlackHole or other drivers.
- Both scripts log what they did and what verification passed.

## Step 4: Documentation and messaging

Update user-facing copy that was added in Phase 6:

- Remove "Output: BlackHole 2ch (dev MVP)" labels from the UI. Replace with `Anti-Bleed_mic - Ready` / `Driver unavailable` states (PLAN 25).
- Update `README.md` installation section: no mention of BlackHole as a prerequisite.
- In `Docs/Driver.md`, add a "History" note that Phase 6 used BlackHole as a scaffold and Phase 9 removed it; keep the licensing warning for historical context but mark it as no longer a runtime dependency.
- If `ANTI_BLEED_MIC_PLAN.md` or any phase doc mentions BlackHole as a required step, add a callout that as of Phase 9 it is dev-only history.

## Step 5: Tests

### Automated (CI + Mac)

```text
NoBlackHoleTests:
  - On a runner/Mac without BlackHole, VirtualMicWriter resolves com.antibleed.writer
    and does NOT attempt to resolve BlackHole2ch_UID.
  - Search: no release source file contains the string "BlackHole" outside Docs/phases.
    (Add a CI grep check that fails if it does.)

DriverStandaloneTests (Mac, requires driver installed):
  - Same WriterToMicLoopTests as Phase 8 - sine injection fidelity, silence on underflow,
    overrun policy - all without BlackHole present.
  - App launch without BlackHole: no error, driver discovered, pipeline starts.
```

### Manual - clean-Mac Discord call

The checklist in Step 2 is the manual test. It must be run and recorded at least once before Phase 9 is marked DONE. The recording is the evidence - not just "tested locally."

## Acceptance criteria

- [ ] No release source file references BlackHole as a runtime path. CI grep check green.
- [ ] `AntiBleed.driver` installs and is discoverable on a Mac that has never had BlackHole.
- [ ] `Anti-Bleed_mic` appears as a standard input in System Settings and Discord without any Audio MIDI Setup configuration; `Anti-Bleed_internal_writer` stays hidden.
- [ ] Discord call via `Anti-Bleed_mic` on a clean Mac reproduces Phase 8 quality: bleed reduced, double-talk intelligible, headphones safe.
- [ ] `Scripts/install-driver.sh` and `uninstall-driver.sh` work on a clean Mac and never touch unrelated drivers.
- [ ] `README.md` and in-app UI no longer present BlackHole as a required or selectable output.
- [ ] `Docs/Testing.md` records the clean-Mac verification (OS version, Mac model, test matrix result).
- [ ] `macos-build.yml` still green; clean-Mac verification logged with real output.

## Pitfalls

- Leaving a silent fallback `if native driver missing -> try BlackHole` in release code - hides a real driver failure and reintroduces the GPL dependency implicitly. Fail visibly instead (`Driver unavailable` state).
- Testing only on the dev Mac that still has BlackHole installed - proves nothing. The clean state is the gate.
- Forgetting to update README/UI copy - users will still search for BlackHole instructions and get confused.

## Next phase gate

Phase 10 may start only when a Discord call on a clean Mac (no BlackHole ever installed or fully uninstalled) succeeds via `Anti-Bleed_mic` with no manual routing. The gate is the clean-Mac checklist with recorded evidence.
