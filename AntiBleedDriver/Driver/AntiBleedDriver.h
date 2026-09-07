// AntiBleed.driver - Core Audio AudioServerPlugIn (HAL) implementing two devices
// that share one ring buffer (D-004, D-005, PLAN 15):
//
//   Anti-Bleed_mic              visible, input-only   (Discord/Zoom select this)
//   Anti-Bleed_internal_writer  hidden,  output-only  (the app writes cleaned PCM)
//
// Format: 48 kHz, Float32, mono, one stream per device. The writer's output
// IOProc pushes into the shared FIFO; the mic's input IOProc pops from it.
// Underflow -> silence (never replay), overflow -> drop oldest.
//
// This file is plain C so it compiles with clang on macOS without Xcode project
// generation (CMake target in AntiBleedDriver/CMakeLists.txt). No GPL code from
// BlackHole is used; the structure follows Apple's public AudioServerPlugIn
// documentation and header contract (see Docs/Driver.md).
#pragma once

#include <CoreAudio/AudioServerPlugIn.h>

// Object IDs published by this plug-in. kAudioObjectPlugInObject is fixed by the HAL.
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_MicDevice     = 2,
    kObjectID_MicStream     = 3,
    kObjectID_WriterDevice  = 4,
    kObjectID_WriterStream  = 5,
};

#define kAntiBleed_Manufacturer     "Anti-Bleed"
#define kAntiBleed_BundleID         "com.antibleed.driver"
#define kAntiBleed_MicName          "Anti-Bleed_mic"
#define kAntiBleed_MicUID           "com.antibleed.mic"
#define kAntiBleed_MicModelUID      "com.antibleed.mic:model"
#define kAntiBleed_WriterName       "Anti-Bleed_internal_writer"
#define kAntiBleed_WriterUID        "com.antibleed.writer"
#define kAntiBleed_WriterModelUID   "com.antibleed.writer:model"

#define kAntiBleed_SampleRate       48000.0
#define kAntiBleed_Channels         1
#define kAntiBleed_RingFrames       (48000 / 2)   // 500 ms of headroom
#define kAntiBleed_SafetyOffset     96            // frames
#define kAntiBleed_Latency          0             // frames

// Custom, read-only diagnostics property on the mic device: CFString "underruns,overruns".
#define kAntiBleed_PropertyRingStats 'abrs'

// CFPlugIn factory (referenced from Info.plist CFPlugInFactories).
extern void* AntiBleedDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
