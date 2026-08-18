#!/bin/bash
set -euo pipefail
# Phase 0 stub. Real implementation in Phase 4.
# Fetches WebRTC outside the repo and builds APM/AEC3.
WEBRTC_REVISION="$(cat WEBRTC_REVISION 2>/dev/null || echo '[not pinned yet]')"
echo "[build-webrtc] WEBRTC_REVISION=${WEBRTC_REVISION}"
if [ "${WEBRTC_REVISION}" = "[not pinned yet]" ]; then
  echo "[build-webrtc] Phase 0: WebRTC build not yet implemented (Phase 4)."
  echo "[build-webrtc] Pin WEBRTC_REVISION and implement depot_tools fetch."
  exit 0
fi
echo "[build-webrtc] Phase 4 build would start here."
echo "[build-webrtc] See phases/PHASE-4-offline-webrtc-aec3.md for full steps."
