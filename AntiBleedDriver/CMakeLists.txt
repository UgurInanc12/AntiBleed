cmake_minimum_required(VERSION 3.20)
project(AntiBleedDriver LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

if(APPLE)
    # AntiBleed.driver bundle -> /Library/Audio/Plug-Ins/HAL/ (Scripts/install-driver.sh)
    add_library(AntiBleed MODULE Driver/AntiBleedDriver.c ../AntiBleedApp/Realtime/abm_ring.c)
    target_include_directories(AntiBleed PRIVATE ../AntiBleedApp/Realtime/include)
    set_target_properties(AntiBleed PROPERTIES
        BUNDLE TRUE
        BUNDLE_EXTENSION "driver"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
        OUTPUT_NAME "AntiBleed"
        PREFIX "")
    target_link_libraries(AntiBleed PRIVATE "-framework CoreAudio" "-framework CoreFoundation")
    target_compile_options(AntiBleed PRIVATE -Wall -Wextra)
    install(TARGETS AntiBleed DESTINATION /Library/Audio/Plug-Ins/HAL)
else()
    message(STATUS "AntiBleedDriver: HAL plug-in is macOS-only; building ring-policy tests only")
endif()

# Platform-independent ring policy tests (Windows/Linux/macOS). Mirrors the
# driver's ring semantics through SharedRingBuffer.
enable_testing()
add_executable(SharedRingBufferTests SharedRingBuffer/SharedRingBuffer.cpp ../Tests/DriverTests/test_shared_ring.cpp)
target_include_directories(SharedRingBufferTests PRIVATE SharedRingBuffer)
add_test(NAME SharedRingBufferTests COMMAND SharedRingBufferTests)
