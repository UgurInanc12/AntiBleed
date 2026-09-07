#!/bin/bash
# Builds WebRTC Audio Processing (APM / AEC3) as a static library into build/webrtc.
# Works on macOS (clang) and Linux; on Windows use the equivalent commands with the
# MSVC environment (see Docs/DSP.md). Pinned by WEBRTC_REVISION.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source WEBRTC_REVISION

PREFIX="$(pwd)/build/webrtc"
WORK="${WEBRTC_WORKDIR:-$HOME/dev/webrtc-audio-processing}"
echo "[build-webrtc] tag=${WEBRTC_APM_TAG} commit=${WEBRTC_APM_COMMIT}"
echo "[build-webrtc] prefix=${PREFIX}"

if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
  echo "[build-webrtc] meson/ninja missing. macOS: brew install meson ninja. Or: pip install meson ninja"
  exit 1
fi

if [ ! -d "${WORK}/.git" ]; then
  git clone --branch "${WEBRTC_APM_TAG}" --depth 1 "${WEBRTC_APM_REPO}" "${WORK}"
fi
cd "${WORK}"
ACTUAL="$(git rev-parse HEAD)"
if [ "${ACTUAL}" != "${WEBRTC_APM_COMMIT}" ]; then
  echo "[build-webrtc] ERROR: checkout is ${ACTUAL}, expected ${WEBRTC_APM_COMMIT}. Refusing to build an unpinned revision."
  exit 2
fi

EXTRA_ARGS=()
if [ "$(uname -s)" = "Darwin" ]; then
  # Universal build is done per-arch by CI; locally build the host arch.
  EXTRA_ARGS+=(-Dneon=auto)
fi

meson setup build --buildtype=release -Ddefault_library=static -Dcpp_std=c++20 --prefix "${PREFIX}" "${EXTRA_ARGS[@]}" --reconfigure 2>/dev/null \
  || meson setup build --buildtype=release -Ddefault_library=static -Dcpp_std=c++20 --prefix "${PREFIX}" "${EXTRA_ARGS[@]}"
meson compile -C build
meson install -C build

# abseil is built as a subproject; AECBridge links it explicitly, so stage its archives too.
mkdir -p "${PREFIX}/lib"
find build/subprojects -name 'libabsl_*.a' -exec cp {} "${PREFIX}/lib/" \;
# License/NOTICE files ship with the release (PLAN 33).
mkdir -p "${PREFIX}/licenses"
cp COPYING "${PREFIX}/licenses/webrtc-audio-processing-COPYING" 2>/dev/null || true
cp webrtc/LICENSE "${PREFIX}/licenses/webrtc-LICENSE" 2>/dev/null || true
cp webrtc/PATENTS "${PREFIX}/licenses/webrtc-PATENTS" 2>/dev/null || true
find build/subprojects -maxdepth 2 -name LICENSE -path '*abseil*' -exec cp {} "${PREFIX}/licenses/abseil-LICENSE" \; 2>/dev/null || true

echo "[build-webrtc] done:"
ls -la "${PREFIX}/lib" | head -n 5
