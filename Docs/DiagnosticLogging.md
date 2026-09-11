# Diagnostic logging

## Using the test build

Logging is enabled by default and remembered across launches. Open Diagnostics:

- **Diagnostic logging (no audio)** toggles new recording.
- **Mark a problem** inserts a timestamped marker. Press it immediately after hearing a glitch.
- **Export diagnostic logs** creates one ZIP at a chosen location. Share this ZIP manually.
- Written/dropped record counts, removed old files and writer errors are visible.

Files live at `~/Library/Logs/AntiBleed/abm-*.jsonl`. JSONL contains one JSON record per
line, with UTC timestamp, session UUID, monotonic elapsed time, event and fields.
The export copies a consistent snapshot before compressing, includes a manifest, and
never uploads anything. Logs retained from earlier sessions are included too.

## Content and limits

- Session: app version/build, packaged Git revision (dirty suffix when applicable),
  package time, macOS version, engine and driver versions.
- Events: start/stop/restart, errors, permission results, device-list changes, selected
  and default output context, configuration changes, install progress/results, sleep/wake,
  problem markers, export and normal application termination.
- State transitions: from/to, explicit decision reason, decision uptime, coupling,
  AEC delay, divergence, ERLE, AEC availability context. Audio decisions are unchanged.
- Health: every approximately one second, min/max/last values across observed 20 Hz UI
  telemetry, nonfinite counts, cumulative counters, per-window deltas/reset markers and
  no-progress indication. Values include levels, correlation, coupling, filter health,
  alignment, synchronization and capture/writer overruns/underruns.
- The 20 Hz telemetry is sampled, not sample-accurate audio capture. A blocked main loop
  yields a longer window; `window_seconds` and `telemetry_samples` make gaps visible.
- No PCM, conversations, password fields or serial-bearing device UIDs are recorded.
  Session-local HAL IDs and device display names are included. Known account/home names
  are redacted on the writer queue, but review device names/error text before sharing.
- At most 20 JSONL files of 5 MiB each. Oldest matching log files are removed on rotation.
  Loss is explicit via `pruned_files` in records/manifest and the UI. This is a size budget,
  not a guarantee that all history is retained forever. Export promptly after testing.
- Pending writes: at most 256 records, each raw field payload at most 16 KiB. Oversized
  records, queue pressure and disk errors increment dropped counts instead of delaying audio.
- All JSON encoding, redaction, directory work and file writes are on a serial utility queue.
  No log/file calls are added to capture, writer IOProc or C ring callbacks. The DSP worker
  only captures transition metadata and dispatches its notification to the control queue.
- Normal quit flushes queued log data. Force quit/crash/power loss may lose the tail and
  will not have `session_end`. No signal-handler file writer or automatic crash dump added.
- Export duplicates retained logs temporarily and compresses outside the writer queue.
  Successful compression is atomically written to the selected destination. Temporary
  staging and ZIP are removed afterward. Ensure free disk space for export as well as logs.

## Verification in this Windows workspace

- 11 new executable Swift tests: JSONL order/redaction, enable/disable, rotation/retention,
  disk failure, oversized records, consistent export snapshot, bounded queue pressure,
  bounded per-record memory, transition reasons, extrema/reset deltas and volume soak.
- The volume test writes 28,800 real records (eight hours at one record/second) in an
  accelerated run with deliberately small retention limits. It is NOT eight hours of
  real audio/device operation. All expected records were written without queue loss;
  retained files stayed within the configured cap and included the latest summary.
- Complete Swift suite: 79 tests passed. Python suite: 113 passed, including three new
  source-wiring checks. Existing Windows SwiftPM symlink warning remains.
- All 26 application Swift files pass syntax parsing. Shell packaging script parses.
- Export snapshot copy/manifest is executed locally. NSSavePanel, macOS ditto ZIP export,
  permissions, termination notification and audio-layer instrumentation still require
  a fresh macOS compile and runtime check. Do not present source checks as Mac execution.

## Mac acceptance

1. Package with the updated package script; verify revision/build time in session_start.
2. Leave logging enabled through a real long Discord call and route changes.
3. Mark glitches; export without stopping audio. Open ZIP and parse every JSONL line.
4. Verify no audio files, passwords, account paths or device serial UIDs are included.
5. Disable logging: after the queued disabled marker drains, no new records should appear.
6. Re-enable, quit normally and relaunch. Old and new sessions must remain exportable.
7. Check writer errors, log dropped counts and retention counts alongside audio counters.
8. Keep the ZIP plus macOS/device names and a short description of what the peer heard.
