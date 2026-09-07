#!/bin/bash
# Removes AntiBleed.driver and restarts coreaudiod. Touches nothing else.
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
[ "$(uname -s)" = "Darwin" ] || { echo "[uninstall-driver] macOS only"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "[uninstall-driver] run with sudo"; exit 1; }
if [ ! -d "${DST}" ]; then echo "[uninstall-driver] ${DST} not present"; exit 0; fi
rm -rf "${DST}"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
sleep 2
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Anti-Bleed_mic"; then
  echo "[uninstall-driver] WARN Anti-Bleed_mic still listed; a reboot may be needed"
else
  echo "[uninstall-driver] OK driver removed"
fi
