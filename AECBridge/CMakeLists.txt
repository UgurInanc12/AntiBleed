cmake_minimum_required(VERSION 3.20)
project(AECBridge LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# Phase 0: standalone stub. Phase 4: link against WebRTC APM.
add_library(AECBridge STATIC
    AECProcessor.cpp
    AECBridge.mm
)

target_include_directories(AECBridge PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# Platform-specific frameworks (macOS)
if(APPLE)
    target_link_libraries(AECBridge PUBLIC "-framework Foundation" "-framework AVFAudio")
endif()

# Phase 4 will append:
#   find_package(WebRTC REQUIRED) or add_subdirectory with archived APM
#   target_link_libraries(AECBridge PRIVATE webrtc_audio_processing)

# Test executable for Phase 0 (passthrough sanity)
add_executable(AECBridgeTests
    ../Tests/AECTests/test_aec_passthrough.cpp
)
target_link_libraries(AECBridgeTests PRIVATE AECBridge)
enable_testing()
add_test(NAME AECBridgeTests COMMAND AECBridgeTests)
