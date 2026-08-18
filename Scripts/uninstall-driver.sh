#!/bin/bash
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
if [ ! -d "${DST}" ]; then
  echo "[uninstall-driver] Driver not installed at ${DST}. Nothing to do."
  exit 0
fi
echo "[uninstall-driver] Removing ${DST}..."
sudo rm -rf "${DST}"
echo "[uninstall-driver] Restarting Core Audio..."
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod 2>/dev/null || true
sleep 1
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Anti-Bleed_mic"; then
  echo "[uninstall-driver] Warning: Anti-Bleed_mic still visible. Core Audio may need a moment or reboot."
else
  echo "[uninstall-driver] Anti-Bleed_mic no longer visible. Done."
fi
