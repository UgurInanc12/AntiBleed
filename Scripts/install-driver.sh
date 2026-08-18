#!/bin/bash
set -euo pipefail
DRIVER="AntiBleed.driver"
SRC="build/AntiBleed.driver"
DST="/Library/Audio/Plug-Ins/HAL/${DRIVER}"
if [ ! -d "${SRC}" ]; then
  echo "[install-driver] Driver bundle not found at ${SRC}. Build it first (Phase 8)."
  exit 1
fi
echo "[install-driver] Installing ${DRIVER} to ${DST}..."
sudo rm -rf "${DST}"
sudo cp -R "${SRC}" "${DST}"
sudo chown -R root:wheel "${DST}"
echo "[install-driver] Restarting Core Audio..."
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod 2>/dev/null || true
sleep 1
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Anti-Bleed_mic"; then
  echo "[install-driver] Anti-Bleed_mic visible."
else
  echo "[install-driver] Warning: Anti-Bleed_mic not yet visible. Check driver bundle and Core Audio restart."
fi
echo "[install-driver] Done."
