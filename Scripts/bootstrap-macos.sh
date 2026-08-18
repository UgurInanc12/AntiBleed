#!/bin/bash
set -euo pipefail
echo "[bootstrap] Anti-Bleed_mic macOS bootstrap"
echo "[bootstrap] Checking Xcode..."
xcodebuild -version || { echo "ERROR: Xcode not found. Install from App Store."; exit 1; }
xcrun --version || { echo "ERROR: Xcode CLT missing. Run: xcode-select --install"; exit 1; }
echo "[bootstrap] Checking depot_tools (for Phase 4 WebRTC)..."
if [ -d "${HOME}/dev/depot_tools" ]; then
  echo "[bootstrap] depot_tools found at ${HOME}/dev/depot_tools"
else
  echo "[bootstrap] depot_tools not found. Phase 4 will install it via Scripts/build-webrtc.sh"
fi
echo "[bootstrap] Checking GN/Ninja..."
which gn >/dev/null 2>&1 && gn --version || echo "[bootstrap] gn not found (will be installed with depot_tools)"
which ninja >/dev/null 2>&1 && ninja --version || echo "[bootstrap] ninja not found (will be installed with depot_tools)"
echo "[bootstrap] Done. Ready for Phase 0 build."
