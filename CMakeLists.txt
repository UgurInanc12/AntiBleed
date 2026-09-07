cmake_minimum_required(VERSION 3.20)
project(AntiBleed LANGUAGES C CXX)

# Umbrella project: builds the native parts on any platform.
#   AECBridge  - WebRTC AEC3 wrapper + C ABI + offline runner (needs build/webrtc, see Scripts/build-webrtc.sh)
#   AntiBleedDriver - HAL plug-in (macOS) + ring policy tests (all platforms)
#   DSP        - legacy C++ mirrors of the Python harness (kept for reference; the product uses AntiBleedCore in Swift)
enable_testing()
add_subdirectory(AECBridge)
add_subdirectory(AntiBleedDriver)
add_subdirectory(DSP)
