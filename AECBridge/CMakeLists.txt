cmake_minimum_required(VERSION 3.20)
project(AECBridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# WebRTC APM / AEC3 (webrtc-audio-processing 2.x, built via Scripts/build-webrtc.sh
# into <repo>/build/webrtc). When absent, AECProcessor compiles as passthrough
# and isRealAEC() returns false so the pipeline stays in BYPASS.
# ---------------------------------------------------------------------------
set(WEBRTC_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../build/webrtc" CACHE PATH "Installed webrtc-audio-processing prefix")
option(ANTIBLEED_REQUIRE_WEBRTC "Fail configure if WebRTC APM is not found" OFF)

set(_WEBRTC_INC "${WEBRTC_PREFIX}/include/webrtc-audio-processing-2")
set(_WEBRTC_LIBDIR "${WEBRTC_PREFIX}/lib")
# Meson emits libwebrtc-audio-processing-2.a even with MSVC, so probe explicit
# file names instead of relying on find_library's per-toolchain suffix list.
set(WEBRTC_APM_LIB "")
foreach(_cand
        "${_WEBRTC_LIBDIR}/libwebrtc-audio-processing-2.a"
        "${_WEBRTC_LIBDIR}/webrtc-audio-processing-2.lib"
        "${_WEBRTC_LIBDIR}/libwebrtc-audio-processing-2.dylib")
    if(EXISTS "${_cand}")
        set(WEBRTC_APM_LIB "${_cand}")
        break()
    endif()
endforeach()

if(WEBRTC_APM_LIB AND EXISTS "${_WEBRTC_INC}/api/audio/audio_processing.h")
    set(ANTIBLEED_HAVE_WEBRTC 1)
    message(STATUS "AECBridge: WebRTC APM found: ${WEBRTC_APM_LIB}")
else()
    set(ANTIBLEED_HAVE_WEBRTC 0)
    if(ANTIBLEED_REQUIRE_WEBRTC)
        message(FATAL_ERROR "AECBridge: WebRTC APM not found under ${WEBRTC_PREFIX}. Run Scripts/build-webrtc.sh")
    endif()
    message(WARNING "AECBridge: WebRTC APM not found under ${WEBRTC_PREFIX}; building passthrough fallback")
endif()

set(AECBRIDGE_SOURCES AECProcessor.cpp aec_c_api.cpp)
if(APPLE)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
    list(APPEND AECBRIDGE_SOURCES AECBridge.mm)
endif()

add_library(AECBridge STATIC ${AECBRIDGE_SOURCES})
target_include_directories(AECBridge PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(AECBridge PUBLIC ANTIBLEED_HAVE_WEBRTC=${ANTIBLEED_HAVE_WEBRTC})

if(ANTIBLEED_HAVE_WEBRTC)
    target_include_directories(AECBridge PRIVATE "${_WEBRTC_INC}" "${WEBRTC_PREFIX}/include")
    target_compile_definitions(AECBridge PRIVATE WEBRTC_LIBRARY_IMPL __STDC_FORMAT_MACROS=1)
    if(WIN32)
        target_compile_definitions(AECBridge PRIVATE WEBRTC_WIN NOMINMAX _USE_MATH_DEFINES)
    elseif(APPLE)
        target_compile_definitions(AECBridge PRIVATE WEBRTC_POSIX WEBRTC_MAC)
    else()
        target_compile_definitions(AECBridge PRIVATE WEBRTC_POSIX WEBRTC_LINUX)
    endif()
    # APM is a static archive; its abseil dependencies must be linked too.
    file(GLOB _ABSL_LIBS "${_WEBRTC_LIBDIR}/libabsl_*.a" "${_WEBRTC_LIBDIR}/absl_*.lib")
    target_link_libraries(AECBridge PUBLIC "${WEBRTC_APM_LIB}" ${_ABSL_LIBS})
    if(WIN32)
        target_link_libraries(AECBridge PUBLIC winmm)
    endif()
endif()

if(APPLE)
    target_link_libraries(AECBridge PUBLIC "-framework Foundation" "-framework AVFAudio")
endif()

# ---------------------------------------------------------------------------
# Tests / tools
# ---------------------------------------------------------------------------
enable_testing()

add_executable(AECBridgeTests ../Tests/AECTests/test_aec_passthrough.cpp)
target_link_libraries(AECBridgeTests PRIVATE AECBridge)
add_test(NAME AECBridgeTests COMMAND AECBridgeTests)

# Offline AEC runner: reads raw Float32 mono 48 kHz render + mic files, writes the
# cleaned output and prints JSON stats. Used by Tests/test_aec3_offline.py.
add_executable(aec_offline ../Tests/AECTests/aec_offline.cpp)
target_link_libraries(aec_offline PRIVATE AECBridge)
