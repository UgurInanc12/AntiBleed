cmake_minimum_required(VERSION 3.20)
project(AntiBleed LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(DSP_TESTS "Build DSP tests" OFF)

if(DSP_TESTS)
    enable_testing()
    # DSP header-only tests are via pytest on Windows; this is for future C++ harness
    # add_subdirectory(Tests/DSPTests) etc. when real C++ tests exist
endif()

# AECBridge is built via AECBridge/CMakeLists.txt on macOS
# DSP is header-only; no separate target needed for Phase 0
