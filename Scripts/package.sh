#!/bin/bash
# Assembles AntiBleed.app from the SwiftPM binary + Info.plist + entitlements, then
# (optionally) signs and notarizes when DEVELOPER_ID / NOTARY_PROFILE are set.
# Usage: Scripts/package.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AntiBleedApp/App/Info.plist)"
BIN=".build/${CONFIG}/AntiBleed"
APP="build/AntiBleed.app"
DRIVER="build/driver/AntiBleed.driver"

[ -f "${BIN}" ] || { echo "[package] ${BIN} missing. Run Scripts/build-app.sh ${CONFIG}"; exit 1; }
[ -d "${DRIVER}" ] || { echo "[package] ${DRIVER} missing. Run Scripts/build-app.sh"; exit 1; }

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Library/Audio/Plug-Ins/HAL"
cp "${BIN}" "${APP}/Contents/MacOS/AntiBleed"
cp AntiBleedApp/App/Info.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string AntiBleed' "${APP}/Contents/Info.plist" 2>/dev/null || true
cp -R "${DRIVER}" "${APP}/Contents/Library/Audio/Plug-Ins/HAL/"
mkdir -p "${APP}/Contents/Resources/licenses"
cp -R build/webrtc/licenses/. "${APP}/Contents/Resources/licenses/" 2>/dev/null || true
cp LICENSE "${APP}/Contents/Resources/licenses/AntiBleed-LICENSE"
cp NOTICE "${APP}/Contents/Resources/licenses/AntiBleed-NOTICE"

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "[package] signing with ${DEVELOPER_ID}"
  codesign --force --options runtime --timestamp --sign "${DEVELOPER_ID}" "${APP}/Contents/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
  codesign --force --options runtime --timestamp --entitlements AntiBleedApp/AntiBleedApp.entitlements --sign "${DEVELOPER_ID}" "${APP}"
  codesign --verify --deep --strict "${APP}"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "${APP}" "build/AntiBleed-${VERSION}.zip"
    xcrun notarytool submit "build/AntiBleed-${VERSION}.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP}"
  fi
else
  echo "[package] DEVELOPER_ID not set: unsigned build (ad-hoc signing for local runs)"
  codesign --force --sign - "${APP}/Contents/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
  codesign --force --sign - --entitlements AntiBleedApp/AntiBleedApp.entitlements "${APP}"
fi

echo "[package] ${APP} (v${VERSION}) ready."
echo "[package] Install the driver from the bundle: sudo Scripts/install-driver.sh ${APP}/Contents/Library/Audio/Plug-Ins/HAL/AntiBleed.driver"
