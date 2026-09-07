#!/bin/bash
# One-time macOS setup for building Anti-Bleed_mic.
set -euo pipefail
echo "[bootstrap] Xcode / CLT"
xcodebuild -version || { echo "Install Xcode (App Store) then: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
xcrun --version >/dev/null || { echo "Run: xcode-select --install"; exit 1; }
swift --version
echo "[bootstrap] Homebrew tools (cmake, meson, ninja)"
if ! command -v brew >/dev/null 2>&1; then echo "Install Homebrew: https://brew.sh"; exit 1; fi
brew list cmake >/dev/null 2>&1 || brew install cmake
brew list meson >/dev/null 2>&1 || brew install meson
brew list ninja >/dev/null 2>&1 || brew install ninja
echo "[bootstrap] Python harness"
python3 -m venv .venv && .venv/bin/pip install -q -r Tests/requirements.txt
echo "[bootstrap] Done. Next: Scripts/build-app.sh"
