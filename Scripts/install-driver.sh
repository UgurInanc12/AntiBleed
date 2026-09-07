#!/bin/bash
# Installs AntiBleed.driver into the HAL plug-in folder and restarts coreaudiod.
# Usage: sudo Scripts/install-driver.sh [path/to/AntiBleed.driver]
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-build/driver/AntiBleed.driver}"
DST="/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"

[ "$(uname -s)" = "Darwin" ] || { echo "[install-driver] macOS only"; exit 1; }
[ -d "${SRC}" ] || { echo "[install-driver] ${SRC} not found. Build it first: cmake -S AntiBleedDriver -B build/driver && cmake --build build/driver"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "[install-driver] run with sudo"; exit 1; }

echo "[install-driver] installing ${SRC} -> ${DST}"
rm -rf "${DST}"
cp -R "${SRC}" "${DST}"
chown -R root:wheel "${DST}"
chmod -R 755 "${DST}"

echo "[install-driver] restarting coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
sleep 2

echo "[install-driver] verifying"
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Anti-Bleed_mic"; then
  echo "  OK  Anti-Bleed_mic is visible as an input device"
else
  echo "  WARN Anti-Bleed_mic not listed yet. Check: log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i antibleed"
fi
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Anti-Bleed_internal_writer"; then
  echo "  WARN hidden writer appears in the public device list (isHidden not honoured?)"
else
  echo "  OK  Anti-Bleed_internal_writer is hidden"
fi
echo "[install-driver] done. Select 'Anti-Bleed_mic' as the microphone in Discord/Zoom."
