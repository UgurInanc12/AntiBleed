cmake_minimum_required(VERSION 3.20)
project(DSP LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(DSP STATIC
    SignalMetrics.cpp
    CrossFade.cpp
    CouplingDetector.cpp
    Resampler.cpp
)

target_include_directories(DSP PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../AECBridge
)

if(APPLE)
    target_link_libraries(DSP PUBLIC "-framework Foundation")
endif()
