# Phase 11: Packaging and Distribution

> PLAN.md chapters: 34, 35, 36, 37, 43.
> Prerequisite: Phase 10 DONE - product UI and recovery complete, clean Mac works without Terminal.
> Status: NOT STARTED

## Objective

Ship a signed, hardened, notarized installer that a user can download, double-click, and use without building from source. The installer places both `AntiBleed.app` and `AntiBleed.driver`, verifies the virtual device appears, and guides the user through the two permission grants. This is the release gate.

Follows PLAN chapters 36 (Installer strategy), 37 (Distribution/security requirements), 34 (Versioning).

## Step 1: Apple Developer Program - prerequisites

Direct distribution outside the Mac App Store (PLAN 37) requires:

```text
Apple Developer Program membership (paid)
Developer ID Application certificate  -> signs AntiBleed.app
Developer ID Installer certificate    -> signs the .pkg
Team ID, e.g., ABCD123456
Notarization credentials              -> Apple ID + app-specific password OR App Store Connect API key
Hardened Runtime capability           -> enabled for the app target
```

Decide early (before this phase starts) whether the product is:

- **Direct distribution** (Developer ID + notarization) - the spec's recommendation for a HAL plug-in, because a system-wide `.driver` does not fit a sandboxed App Store model.
- **Mac App Store** - not recommended for v1 (PLAN 37). If later desired, it is a separate decision with entitlements and sandbox analysis.

Record the choice in `phases/DECISIONS.md` (new D-0xx) and never commit certificates or API keys.

## Step 2: Versioning and build metadata (PLAN 34)

Pin and surface:

```text
Anti-Bleed version      -> CFBundleShortVersionString / CFBundleVersion in AntiBleedApp/Info.plist
Git commit              -> git rev-parse HEAD at build time, embedded in Diagnostics
WEBRTC_REVISION         -> content of WEBRTC_REVISION file
Driver version          -> CFBundleShortVersionString in AntiBleedDriver/Info.plist (must match app major)
macOS deployment target -> 14.2
Xcode version           -> pinned in CI (phases/README.md, D-014)
Compiler settings       -> SWIFT_VERSION, CMAKE_CXX_STANDARD
DSP config schema       -> version field in any tuning plist/json
```

Diagnostics (Phase 10's DiagnosticsView) must show all of these:

```text
Anti-Bleed 0.9.0 (git abc1234) / WebRTC a1b2c3d / Driver 0.9.0 / macOS 14.4 / arm64
```

Add a `Scripts/version.sh` that stamps these into `Info.plist` files before `xcodebuild`.

## Step 3: Signing - what is signed and how

Sign in this order, with the same Developer ID identity:

```text
1. AntiBleed.driver  (the HAL plug-in bundle)
2. AntiBleed.app     (the menu bar app, which embeds/knows the driver version)
3. AntiBleed.pkg     (the installer package containing both)
```

### Entitlements and Hardened Runtime

`AntiBleedApp/AntiBleedApp.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key><false/> <!-- HAL plug-in requires non-sandboxed context; verify -->
<key>com.apple.security.cs.allow-jit</key><false/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><false/>
<key>com.apple.security.device.audio-input</key><true/>
<!-- Add only what Apple requires; do not add broad entitlements to "make it work" -->
```

Enable Hardened Runtime in the Xcode target (`CODE_SIGN_STYLE = Manual`, `ENABLE_HARDENED_RUNTIME = YES`). Notarization requires it.

Verify local signing before notarization:

```bash
codesign --verify --deep --strict --verbose=2 AntiBleed.app
codesign --verify --deep --strict --verbose=2 /Library/Audio/Plug-Ins/HAL/AntiBleed.driver
spctl -a -vvv -t install AntiBleed.pkg
```

Any `rejected` or `unsealed contents present` failure must be fixed before uploading for notarization.

## Step 4: Notarization and stapling

```bash
# 1. Create the .pkg (see Step 5) then submit:
xcrun notarytool submit AntiBleed-0.9.0.pkg \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --wait

# Or with API key:
xcrun notarytool submit AntiBleed-0.9.0.pkg \
  --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" --wait

# 2. Check status:
xcrun notarytool log <submission-id> --key ... # read JSON for issues

# 3. Staple the ticket:
xcrun stapler staple AntiBleed-0.9.0.pkg
xcrun stapler validate AntiBleed-0.9.0.pkg

# 4. Also staple the app if distributing a .dmg variant:
xcrun stapler staple AntiBleed.app
```

Gatekeeper verification (on a clean Mac, offline):

```bash
spctl -a -vvv -t install AntiBleed-0.9.0.pkg
# must say "accepted" with source "Developer ID"
```

Record the notarization workflow in `Docs/Distribution.md` verbatim so a future release can repeat it.

Secret handling:

- Certificates (`.p12`) and API keys are stored only in GitHub Actions Secrets and on the release Mac's keychain. Never committed.
- `APP_SPECIFIC_PASSWORD` / API key never appears in logs. Use `::add-mask::` in Actions if needed.

## Step 5: Installer - what it does (PLAN 36)

The installer must place both artifacts and verify the result. Recommended format: signed `.pkg` (preferred for HAL plug-ins) or a `.dmg` containing the `.pkg` and a ReadMe.

### Installer contents

```text
AntiBleed-0.9.0.pkg
  ├── AntiBleed.app  -> /Applications/AntiBleed.app
  └── AntiBleed.driver -> /Library/Audio/Plug-Ins/HAL/AntiBleed.driver
```

Build with `pkgbuild` + `productbuild` or `Packages` / `create-dmg` tooling - pin the tool and document it.

Example skeleton:

```bash
#!/bin/bash
set -euo pipefail
VERSION="0.9.0"
IDENTITY="Developer ID Installer: Your Name (TEAMID)"

# 1. Build signed .app and .driver
./Scripts/build-app.sh --configuration Release
./Scripts/build-driver.sh --configuration Release

# 2. Stage
rm -rf pkgroot
mkdir -p pkgroot/Applications pkgroot/Library/Audio/Plug-Ins/HAL
cp -R build/Release/AntiBleed.app pkgroot/Applications/
cp -R build/Release/AntiBleed.driver pkgroot/Library/Audio/Plug-Ins/HAL/

# 3. Component package
pkgbuild --root pkgroot \
  --identifier com.antibleed.installer \
  --version "$VERSION" \
  --install-location / \
  --sign "$IDENTITY" \
  AntiBleed-0.9.0-component.pkg

# 4. Product archive (with distribution.xml if needed)
productbuild --distribution Distribution.xml \
  --package-path . \
  --sign "$IDENTITY" \
  AntiBleed-0.9.0.pkg
```

### Installer behavior checklist (PLAN 36 + 43 DoD)

The installer (and its postinstall script) must:

```text
1. Verify macOS >= 14.2, fail with a clear message on older OS.
2. Install AntiBleed.app to /Applications.
3. Install AntiBleed.driver to /Library/Audio/Plug-Ins/HAL/ (requires admin - prompt once).
4. Fix ownership: root:wheel on the driver bundle.
5. Restart/reload Core Audio (launchctl kickstart -k system/com.apple.audio.coreaudiod).
6. Verify Anti-Bleed_mic appears (system_profiler / AudioObject check).
7. Launch /Applications/AntiBleed.app.
8. The app then requests mic + system-audio permissions through its own UI (installer does not grant them).
```

Postinstall verification (inside the package's `postinstall` script):

```bash
sleep 1
if ! system_profiler SPAudioDataType | grep -q "Anti-Bleed_mic"; then
  echo "Warning: Anti-Bleed_mic not visible after install. Try restarting." >&2
  exit 0  # do not fail the install, but surface the warning
fi
open -a "/Applications/AntiBleed.app" || true
```

### Uninstaller

Must remove exactly what was installed and nothing else:

```text
/Applications/AntiBleed.app
/Library/Audio/Plug-Ins/HAL/AntiBleed.driver
~/Library/Preferences/com.antibleed.*  (optional, with user consent)
~/Library/Logs/AntiBleed/              (optional)
```

Must not remove BlackHole, other HAL drivers, or unrelated preferences. Provide `Scripts/uninstall-driver.sh` and an uninstall entry in the app's Settings.

## Step 6: CI - Release workflow

Add `.github/workflows/release.yml` (manual dispatch + tag trigger):

```yaml
name: Release
on:
  push:
    tags: ['v*']
  workflow_dispatch:
jobs:
  build-and-notarize:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Select pinned Xcode
        run: sudo xcode-select -s /Applications/Xcode_*.app
      - name: Import signing certificates
        run: |
          echo "$APPLE_CERT_P12_B64" | base64 --decode > /tmp/cert.p12
          security import /tmp/cert.p12 -P "$APPLE_CERT_PASSWORD" -k ~/Library/Keychains/login.keychain-db
          # same for installer cert
      - name: Build signed app + driver
        run: |
          ./Scripts/build-app.sh --configuration Release
          ./Scripts/build-driver.sh --configuration Release
          codesign --verify --deep --strict --verbose=2 build/Release/AntiBleed.app
          codesign --verify --deep --strict --verbose=2 build/Release/AntiBleed.driver
      - name: Build signed pkg
        run: ./Scripts/package.sh --version "${GITHUB_REF_NAME#v}"
      - name: Notarize
        run: |
          xcrun notarytool submit build/AntiBleed-*.pkg \
            --key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" --wait
          xcrun stapler staple build/AntiBleed-*.pkg
          spctl -a -vvv -t install build/AntiBleed-*.pkg
      - name: Checksum and upload
        run: |
          shasum -a 256 build/AntiBleed-*.pkg > build/AntiBleed-*.pkg.sha256
          # upload to GitHub Release via gh release upload
```

Pin `macos-14` and the exact Xcode version. Secrets required:

```text
APPLE_CERT_P12_B64, APPLE_CERT_PASSWORD,
APPLE_INSTALLER_CERT_P12_B64, APPLE_INSTALLER_CERT_PASSWORD,
API_KEY_CONTENT (or path), API_KEY_ID, API_ISSUER_ID, TEAM_ID
```

No secret is ever logged.

## Step 7: Hardware validation gate (PLAN 35 - "Do not mark audio validated on CI alone")

Before any tag is pushed, run the hardware matrix on a real Mac and record it in `Docs/Testing.md`:

```text
- 25/50/75% speaker volumes x speech/music/game/SFX x silent/continuous/intermittent/double-talk
- Lid angle, desk move, room switch
- Headphones/mute/volume-0 bypass
- Route change and sleep/wake recovery
- Discord call via Anti-Bleed_mic (clean Mac, no BlackHole)
- Measured: echo reduction >= 20 dB representative, latency < 50 ms, no inverse on headphones
```

CI green is necessary but not sufficient. Hardware evidence is the release gate.

## Step 8: Distribution - what the user downloads

Publish as a GitHub Release (or website download) containing:

```text
AntiBleed-0.9.0.pkg              # signed + notarized + stapled
AntiBleed-0.9.0.pkg.sha256       # checksum
README.md / Release Notes        # changelog, supported macOS, known limitations
```

Optionally also a `.dmg` variant. The download page must state:

- Supported macOS: 14.2+
- Permissions required: Microphone + System Audio (local only, no upload)
- How to verify: `spctl -a -vvv -t install AntiBleed-0.9.0.pkg` should say `accepted`
- Uninstall instructions

## Acceptance criteria

- [ ] App, driver, and installer are all signed with Developer ID; `codesign --verify --deep --strict` and `spctl -a -vvv` both say accepted on the built artifacts.
- [ ] Installer is notarized and stapled; `xcrun stapler validate` and offline `spctl` both pass on a clean Mac.
- [ ] Fresh install on a clean Mac (no prior AntiBleed, no BlackHole) via double-clicking the .pkg:
  - installs to /Applications and /Library/Audio/Plug-Ins/HAL with correct ownership,
  - restarts Core Audio, Anti-Bleed_mic appears,
  - launches the app, permissions flow works, Discord call succeeds,
  - no manual Audio MIDI Setup or Terminal step required.
- [ ] Uninstaller removes only AntiBleed artifacts without touching other drivers.
- [ ] Release workflow in GitHub Actions builds, signs, notarizes, staples, checksums, and uploads the artifact using only secrets (no cert committed).
- [ ] Diagnostics shows the full version string (app / driver / WebRTC / macOS / arch) for the shipped build.
- [ ] Hardware validation matrix re-run for the release build with measured numbers recorded in Docs/Testing.md.
- [ ] Docs/Distribution.md documents the exact signing/notarization/installer steps so the next release is reproducible.

## Pitfalls

- Signing the .pkg but not the .app/.driver inside it - Gatekeeper rejects the inner bundles.
- Forgetting Hardened Runtime - notarization fails.
- Committing .p12 or API keys - revokes the identity and leaks trust. Use GitHub Secrets + keychain only.
- Stapling the .pkg but distributing an unstapled copy - offline verification fails. Staple before upload.
- Testing the installer only on the dev Mac that already has the driver - the clean Mac test is the real one.
- Distributing via Mac App Store without analyzing HAL plug-in sandbox constraints - the spec recommends direct distribution for v1.

## Definition of Done (release)

All 20 items from PLAN 43 plus the phase criteria above. The product is complete for v1 when:

```text
1. Clean Mac -> double-click .pkg -> Anti-Bleed_mic appears.
2. Discord -> Input = Anti-Bleed_mic works with no manual routing.
3. AEC removes speaker bleed, double-talk preserved, headphones safe, no inverse.
4. Route changes and failures fall back safely.
5. Processing is local only, no upload.
6. Build is reproducible, signed, notarized, and hardware-validated.
```
