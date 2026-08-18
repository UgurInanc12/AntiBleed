# Anti-Bleed_mic: Distribution

> Master spec: ../ANTI_BLEED_MIC_PLAN.md chapters 34, 36, 37, 43.
> Status: stub - filled in Phase 11.

## 1. Target

Direct distribution (Developer ID + Hardened Runtime + notarization), not Mac App Store for v1. A system-wide HAL Audio Server Plug-in does not fit a sandboxed App Store model (PLAN 37).

## 2. What is signed (same Developer ID identity, in order)

1. `AntiBleed.driver` (HAL plug-in bundle)
2. `AntiBleed.app` (menu bar app)
3. `AntiBleed.pkg` (installer containing both)

Hardened Runtime enabled for the app target; entitlements minimal. See `phases/PHASE-11-*` for the exact entitlements and verification commands.

## 3. Notarization

```bash
xcrun notarytool submit AntiBleed-0.9.0.pkg --apple-id ... --team-id ... --password ... --wait
xcrun notarytool log <submission-id> ...
xcrun stapler staple AntiBleed-0.9.0.pkg
xcrun stapler validate AntiBleed-0.9.0.pkg
spctl -a -vvv -t install AntiBleed-0.9.0.pkg  # must say "accepted" (Developer ID)
```

Secrets (.p12, API keys) live only in GitHub Actions Secrets and the release Mac's keychain, never in the repo.

## 4. Installer behavior (PLAN 36)

Verify macOS >= 14.2, install app to `/Applications` and driver to `/Library/Audio/Plug-Ins/HAL/` (admin once), chown root:wheel, restart Core Audio, verify `Anti-Bleed_mic` appears, launch the app - the app then guides mic + system-audio permission grants. Uninstaller removes only Anti-Bleed artifacts.

## 5. Versioning (PLAN 34)

Pinned: Xcode major, macOS deployment target, `WEBRTC_REVISION`, compiler settings, driver ABI, DSP config schema. Surfaced in Diagnostics as `app / git / WebRTC / driver / macOS / arch`. See `phases/PHASE-11-*` and `Scripts/version.sh`.

## 6. CI release workflow

Tag-triggered + manual dispatch; builds, signs, notarizes, staples, checksums, and uploads to a GitHub Release. See `phases/PHASE-11-*` for the exact `release.yml`.

## 7. Release checklist - fill per release

| Item | Command / evidence | Result |
|------|--------------------|--------|
| `codesign --verify --deep --strict` app |  |  |
| `codesign --verify --deep --strict` driver |  |  |
| `spctl -a -vvv -t install` pkg |  |  |
| `stapler validate` |  |  |
| Clean-Mac install (no prior AntiBleed, no BlackHole) |  |  |
| Hardware matrix (attenuation / double-talk / no-inverse / latency) |  |  |
| Checksum published |  |  |

## 8. What the user downloads

```
AntiBleed-0.9.0.pkg
AntiBleed-0.9.0.pkg.sha256
Release notes (supported macOS, permissions, verify instructions, uninstall)
```
Supported macOS 14.2+, permissions: Microphone + System Audio (local only).
