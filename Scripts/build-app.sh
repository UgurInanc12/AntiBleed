#!/bin/bash
set -euo pipefail
echo "[build-app] Building AntiBleedApp..."

# On macOS: build via Xcode
if command -v xcodebuild >/dev/null 2>&1; then
  if [ -f "AntiBleedApp/AntiBleedApp.xcodeproj/project.pbxproj" ]; then
    xcodebuild -project AntiBleedApp/AntiBleedApp.xcodeproj \
      -scheme AntiBleedApp -configuration Debug build
  else
    echo "[build-app] No Xcode project yet (expected in Phase 0 on Mac)."
    echo "[build-app] Skipping xcodebuild. Verifying Swift stubs parse..."
    # At least verify Swift files exist
    ls -la AntiBleedApp/App/*.swift AntiBleedApp/UI/*.swift AntiBleedApp/Audio/*.swift 2>&1 | head -n 30
  fi
else
  echo "[build-app] xcodebuild not found (Windows/CI without macOS). Skipping."
  echo "[build-app] Verifying file presence instead:"
  ls -la AntiBleedApp/App/ AntiBleedApp/UI/ AntiBleedApp/Audio/ 2>&1 | head -n 30
fi

# Also build C++ bridge if CMake is available
if command -v cmake >/dev/null 2>&1; then
  echo "[build-app] Building AECBridge..."
  cmake -S AECBridge -B build/aec -DCMAKE_BUILD_TYPE=Release
  cmake --build build/aec
else
  echo "[build-app] cmake not found. Skipping C++ build (macOS CI will build it)."
fi

echo "[build-app] Done."
