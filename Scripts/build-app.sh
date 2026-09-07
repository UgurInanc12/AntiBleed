#!/bin/bash
# Full macOS build: WebRTC APM -> AECBridge -> AntiBleed.driver -> AntiBleed app (SwiftPM).
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[build-app] Not macOS. On Windows use:"
  echo "  cmake -S AECBridge -B build/aec -G \"Visual Studio 16 2019\" -A x64 && cmake --build build/aec --config Release"
  echo "  Scripts/swift-test-windows.cmd     (core unit tests)"
  echo "  .venv/Scripts/pytest               (offline AEC3 + integration tests)"
  exit 0
fi

echo "[build-app] 1/4 WebRTC APM"
if [ ! -f build/webrtc/lib/libwebrtc-audio-processing-2.a ]; then
  Scripts/build-webrtc.sh
else
  echo "  cached: build/webrtc"
fi

echo "[build-app] 2/4 AECBridge (C++/ObjC++ + C ABI)"
cmake -S AECBridge -B build/aec -DCMAKE_BUILD_TYPE=Release -DANTIBLEED_REQUIRE_WEBRTC=ON
cmake --build build/aec
ctest --test-dir build/aec --output-on-failure

echo "[build-app] 3/4 AntiBleed.driver"
cmake -S AntiBleedDriver -B build/driver -DCMAKE_BUILD_TYPE=Release
cmake --build build/driver
ctest --test-dir build/driver --output-on-failure
echo "  bundle: build/driver/AntiBleed.driver (install with sudo Scripts/install-driver.sh)"

echo "[build-app] 4/4 Swift package"
swift build -c "${CONFIG}" --product AntiBleed
swift test

APP_BIN=".build/${CONFIG}/AntiBleed"
echo "[build-app] binary: ${APP_BIN}"
echo "[build-app] To bundle as AntiBleed.app: Scripts/package.sh ${CONFIG}"
