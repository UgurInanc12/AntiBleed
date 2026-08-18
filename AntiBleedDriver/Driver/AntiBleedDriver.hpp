#pragma once
// Phase 8: Audio Server Plug-in entry points.
// On macOS this implements the HAL plug-in interface (AudioServerPlugInDriverInterface).
// Stub header for Windows/CI so the project structure is complete.

#ifdef __APPLE__
#include <CoreAudio/AudioServerPlugIn.h>
extern "C" {
    void* AntiBleedDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
}
#endif

// Device UIDs
#define kAntiBleedMicUID "com.antibleed.mic"
#define kAntiBleedWriterUID "com.antibleed.writer"
#define kAntiBleedMicName "Anti-Bleed_mic"
#define kAntiBleedWriterName "Anti-Bleed_internal_writer"
