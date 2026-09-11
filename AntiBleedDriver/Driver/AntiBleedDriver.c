// AntiBleed.driver implementation. See AntiBleedDriver.h for the object model.
//
// Threading: property access is serialised with a mutex (host control thread).
// IO methods run on the HAL's real-time IO threads and touch only the
// preallocated ring + atomics. The two devices share one clock (the writer's
// zero timestamp domain) so that the HAL keeps their sample timelines aligned.

#include "AntiBleedDriver.h"
#include "abm_ring.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// -------------------------------------------------------------------- state

static abm_fifo_t* gRing;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static ULONG gRefCount = 0;

// Per-device IO state. Both devices run on a shared timeline.
typedef struct {
    _Atomic UInt32 ioRunning;      // number of clients that called StartIO (read lock-free in IO)
    Float64 sampleTime;            // zero timestamp sample time
    UInt64 hostTime;               // zero timestamp host time
    UInt64 seed;
} device_io_t;

static device_io_t gMicIO, gWriterIO;
static Float64 gHostTicksPerFrame = 0.0;
static const UInt32 kZeroTimeStampPeriod = 4800; // frames between zero-timestamp updates (100 ms)

// Forward
static AudioServerPlugInDriverInterface gDriverInterface;
static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;



// -------------------------------------------------------------------- helpers

static Boolean isDevice(AudioObjectID id) { return id == kObjectID_MicDevice || id == kObjectID_WriterDevice; }
static Boolean isStream(AudioObjectID id) { return id == kObjectID_MicStream || id == kObjectID_WriterStream; }
static Boolean isMic(AudioObjectID id) { return id == kObjectID_MicDevice || id == kObjectID_MicStream; }
static device_io_t* ioFor(AudioObjectID dev) { return dev == kObjectID_MicDevice ? &gMicIO : &gWriterIO; }

// A device owns exactly one stream: input scope for the mic, output scope for the writer.
// Global scope lists it too. Any other scope yields an empty list (size 0).
static UInt32 streamListSize(AudioObjectID dev, AudioObjectPropertyScope scope) {
    Boolean mic = (dev == kObjectID_MicDevice);
    Boolean wants = (scope == kAudioObjectPropertyScopeGlobal)
                 || (mic && scope == kAudioObjectPropertyScopeInput)
                 || (!mic && scope == kAudioObjectPropertyScopeOutput);
    return wants ? (UInt32)sizeof(AudioObjectID) : 0;
}

static AudioStreamBasicDescription canonicalFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kAntiBleed_SampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = sizeof(float) * kAntiBleed_Channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(float) * kAntiBleed_Channels;
    f.mChannelsPerFrame = kAntiBleed_Channels;
    f.mBitsPerChannel = 32;
    return f;
}

#define RETURN_CFSTRING(str)                                                        \
    do { if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
         *((CFStringRef*)outData) = CFSTR(str); *outDataSize = sizeof(CFStringRef); return 0; } while (0)
#define RETURN_UINT32(v)                                                            \
    do { if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;      \
         *((UInt32*)outData) = (UInt32)(v); *outDataSize = sizeof(UInt32); return 0; } while (0)
#define RETURN_FLOAT64(v)                                                           \
    do { if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;     \
         *((Float64*)outData) = (Float64)(v); *outDataSize = sizeof(Float64); return 0; } while (0)

// -------------------------------------------------------------------- IUnknown

static HRESULT AB_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    (void)inDriver;
    if (!outInterface) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean ok = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!ok) { *outInterface = NULL; return E_NOINTERFACE; }
    ++gRefCount;
    *outInterface = gDriverRef;
    return S_OK;
}
static ULONG AB_AddRef(void* inDriver) { (void)inDriver; return ++gRefCount; }
static ULONG AB_Release(void* inDriver) { (void)inDriver; if (gRefCount > 0) --gRefCount; return gRefCount; }

// -------------------------------------------------------------------- lifecycle

static OSStatus AB_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    Float64 hostClockFrequency = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = hostClockFrequency / kAntiBleed_SampleRate;
    gRing = abm_fifo_create(kAntiBleed_RingFrames);
    if (!gRing) return kAudioHardwareUnspecifiedError;
    memset(&gMicIO, 0, sizeof gMicIO);
    memset(&gWriterIO, 0, sizeof gWriterIO);
    return 0;
}

static OSStatus AB_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus AB_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AB_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) { (void)d; (void)ci; return isDevice(id) ? 0 : kAudioHardwareBadObjectError; }
static OSStatus AB_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* ci) { (void)d; (void)ci; return isDevice(id) ? 0 : kAudioHardwareBadObjectError; }
static OSStatus AB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) { (void)d; (void)a; (void)i; return isDevice(id) ? 0 : kAudioHardwareBadObjectError; }
static OSStatus AB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) { (void)d; (void)a; (void)i; return isDevice(id) ? 0 : kAudioHardwareBadObjectError; }

// -------------------------------------------------------------------- properties

static Boolean AB_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)inDriver; (void)pid;
    if (!a) return false;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default: return false;
        }
    case kObjectID_MicDevice: case kObjectID_WriterDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyStreams: case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return true;
        case kAntiBleed_PropertyRingStats: case kAudioObjectPropertyCustomPropertyInfoList:
            return id == kObjectID_MicDevice;
        default: return false;
        }
    case kObjectID_MicStream: case kObjectID_WriterStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default: return false;
        }
    }
    return false;
}

static OSStatus AB_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    if (!AB_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    // Nothing is settable: the format is fixed to 48 kHz Float32 mono (D-007).
    // Accepting a NominalSampleRate "set" to 48000 is handled in SetPropertyData.
    *out = (a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kAudioStreamPropertyVirtualFormat
            || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return 0;
}

static OSStatus AB_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                       UInt32 qsz, const void* q, UInt32* outSize) {
    (void)qsz; (void)q;
    if (!AB_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        *outSize = sizeof(UInt32); return 0;
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyName: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
        *outSize = sizeof(CFStringRef); return 0;
    case kAudioDevicePropertyIcon:
        *outSize = sizeof(CFURLRef); return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (id == kObjectID_PlugIn) { *outSize = 2 * sizeof(AudioObjectID); return 0; }
        if (isDevice(id)) { *outSize = streamListSize(id, a->mScope); return 0; }
        *outSize = 0; return 0;
    case kAudioPlugInPropertyDeviceList:
        *outSize = 2 * sizeof(AudioObjectID); return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyRelatedDevices:
        *outSize = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyStreams:
        *outSize = streamListSize(id, a->mScope); return 0;
    case kAudioObjectPropertyControlList:
        *outSize = 0; return 0;
    case kAudioDevicePropertyNominalSampleRate:
        *outSize = sizeof(Float64); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *outSize = sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outSize = 2 * sizeof(UInt32); return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kAntiBleed_Channels * sizeof(AudioChannelDescription); return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *outSize = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *outSize = sizeof(AudioStreamRangedDescription); return 0;
    case kAntiBleed_PropertyRingStats:
        *outSize = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyCustomPropertyInfoList:
        *outSize = sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus AB_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qsz, const void* q, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (!AB_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    Boolean mic = isMic(id);

    // ---- plug-in
    if (id == kObjectID_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_UINT32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_UINT32(kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_UINT32(kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(kAntiBleed_Manufacturer);
        case kAudioPlugInPropertyResourceBundle: RETURN_CFSTRING("");
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            UInt32 n = inDataSize / sizeof(AudioObjectID); AudioObjectID* o = (AudioObjectID*)outData;
            UInt32 w = 0;
            if (n > w) o[w++] = kObjectID_MicDevice;
            if (n > w) o[w++] = kObjectID_WriterDevice;
            *outDataSize = w * sizeof(AudioObjectID); return 0;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qsz != sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef*)q);
            AudioObjectID r = kAudioObjectUnknown;
            if (uid && CFStringCompare(uid, CFSTR(kAntiBleed_MicUID), 0) == kCFCompareEqualTo) r = kObjectID_MicDevice;
            else if (uid && CFStringCompare(uid, CFSTR(kAntiBleed_WriterUID), 0) == kCFCompareEqualTo) r = kObjectID_WriterDevice;
            *((AudioObjectID*)outData) = r; *outDataSize = sizeof(AudioObjectID); return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    // ---- devices
    if (isDevice(id)) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_UINT32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_UINT32(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_UINT32(kObjectID_PlugIn);
        case kAudioObjectPropertyName: if (mic) RETURN_CFSTRING(kAntiBleed_MicName); else RETURN_CFSTRING(kAntiBleed_WriterName);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(kAntiBleed_Manufacturer);
        case kAudioDevicePropertyDeviceUID: if (mic) RETURN_CFSTRING(kAntiBleed_MicUID); else RETURN_CFSTRING(kAntiBleed_WriterUID);
        case kAudioDevicePropertyModelUID: if (mic) RETURN_CFSTRING(kAntiBleed_MicModelUID); else RETURN_CFSTRING(kAntiBleed_WriterModelUID);
        case kAudioDevicePropertyTransportType: RETURN_UINT32(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: RETURN_UINT32(0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_UINT32(1);
        case kAudioDevicePropertyDeviceIsRunning: {
            RETURN_UINT32(atomic_load(&ioFor(id)->ioRunning) > 0 ? 1 : 0);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            // Only the mic can be a default device, and only as an INPUT default.
            RETURN_UINT32((mic && a->mScope == kAudioObjectPropertyScopeInput) ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_UINT32(0);
        case kAudioDevicePropertyIsHidden: RETURN_UINT32(mic ? 0 : 1);   // D-005: writer hidden
        case kAudioDevicePropertyLatency: RETURN_UINT32(kAntiBleed_Latency);
        case kAudioDevicePropertySafetyOffset: RETURN_UINT32(kAntiBleed_SafetyOffset);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_UINT32(kZeroTimeStampPeriod);
        case kAudioDevicePropertyNominalSampleRate: RETURN_FLOAT64(kAntiBleed_SampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            if (inDataSize < sizeof(AudioValueRange)) { *outDataSize = 0; return 0; }
            AudioValueRange* r = (AudioValueRange*)outData; r->mMinimum = r->mMaximum = kAntiBleed_SampleRate;
            *outDataSize = sizeof(AudioValueRange); return 0;
        }
        case kAudioDevicePropertyIcon: {
            if (inDataSize < sizeof(CFURLRef)) return kAudioHardwareBadPropertySizeError;
            CFBundleRef b = CFBundleGetBundleWithIdentifier(CFSTR(kAntiBleed_BundleID));
            CFURLRef url = b ? CFBundleCopyResourceURL(b, CFSTR("AntiBleed"), CFSTR("icns"), NULL) : NULL;
            if (!url) return kAudioHardwareUnknownPropertyError;
            *((CFURLRef*)outData) = url; *outDataSize = sizeof(CFURLRef); return 0;
        }
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            if (streamListSize(id, a->mScope) == 0 || inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            *((AudioObjectID*)outData) = mic ? kObjectID_MicStream : kObjectID_WriterStream;
            *outDataSize = sizeof(AudioObjectID); return 0;
        }
        case kAudioDevicePropertyRelatedDevices: {
            if (inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            *((AudioObjectID*)outData) = id; *outDataSize = sizeof(AudioObjectID); return 0;
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 1; *outDataSize = 2 * sizeof(UInt32); return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 need = offsetof(AudioChannelLayout, mChannelDescriptions) + kAntiBleed_Channels * sizeof(AudioChannelDescription);
            if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mChannelBitmap = 0; l->mNumberChannelDescriptions = kAntiBleed_Channels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            l->mChannelDescriptions[0].mChannelFlags = 0;
            memset(l->mChannelDescriptions[0].mCoordinates, 0, sizeof l->mChannelDescriptions[0].mCoordinates);
            *outDataSize = need; return 0;
        }
        case kAntiBleed_PropertyRingStats: {
            // Custom properties may only be CFString or CFPropertyList. Format: "underruns,overruns".
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            unsigned long long u = (unsigned long long)abm_fifo_underruns(gRing);
            unsigned long long o = (unsigned long long)abm_fifo_overruns(gRing);
            *((CFStringRef*)outData) = CFStringCreateWithFormat(NULL, NULL, CFSTR("%llu,%llu"), u, o);
            *outDataSize = sizeof(CFStringRef); return 0;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            // Declares 'abrs' so the HAL can marshal it to clients.
            if (inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) { *outDataSize = 0; return 0; }
            AudioServerPlugInCustomPropertyInfo* info = (AudioServerPlugInCustomPropertyInfo*)outData;
            info->mSelector = kAntiBleed_PropertyRingStats;
            info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFString;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    // ---- streams
    if (isStream(id)) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_UINT32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_UINT32(kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_UINT32(mic ? kObjectID_MicDevice : kObjectID_WriterDevice);
        case kAudioObjectPropertyName: if (mic) RETURN_CFSTRING("Anti-Bleed_mic input"); else RETURN_CFSTRING("Anti-Bleed writer output");
        case kAudioStreamPropertyIsActive: RETURN_UINT32(1);
        case kAudioStreamPropertyDirection: RETURN_UINT32(mic ? 1 : 0); // 1 = input, 0 = output
        case kAudioStreamPropertyTerminalType: RETURN_UINT32(mic ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_UINT32(1);
        case kAudioStreamPropertyLatency: RETURN_UINT32(0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            *((AudioStreamBasicDescription*)outData) = canonicalFormat();
            *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
        }
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inDataSize < sizeof(AudioStreamRangedDescription)) { *outDataSize = 0; return 0; }
            AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
            r->mFormat = canonicalFormat();
            r->mSampleRateRange.mMinimum = r->mSampleRateRange.mMaximum = kAntiBleed_SampleRate;
            *outDataSize = sizeof(AudioStreamRangedDescription); return 0;
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus AB_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qsz, const void* q, UInt32 inDataSize, const void* inData) {
    (void)qsz; (void)q;
    if (!AB_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return (*((const Float64*)inData) == kAntiBleed_SampleRate) ? 0 : kAudioHardwareIllegalOperationError;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
        AudioStreamBasicDescription c = canonicalFormat();
        return (f->mSampleRate == c.mSampleRate && f->mFormatID == c.mFormatID && f->mChannelsPerFrame == c.mChannelsPerFrame
                && f->mBitsPerChannel == c.mBitsPerChannel) ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    }
    return kAudioHardwareUnsupportedOperationError;
}

// -------------------------------------------------------------------- IO

static OSStatus AB_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 clientID) {
    (void)inDriver; (void)clientID;
    if (!isDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    device_io_t* io = ioFor(id);
    if (atomic_load(&io->ioRunning) == 0) {
        io->sampleTime = 0;
        io->hostTime = mach_absolute_time();
        io->seed++;
        // A mic callback may still be reading during a writer restart.
        if (id == kObjectID_WriterDevice && !abm_fifo_try_reset(gRing)) {
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareUnspecifiedError;
        }
    }
    atomic_fetch_add(&io->ioRunning, 1);
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus AB_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 clientID) {
    (void)inDriver; (void)clientID;
    if (!isDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    device_io_t* io = ioFor(id);
    if (atomic_load(&io->ioRunning) > 0) atomic_fetch_sub(&io->ioRunning, 1);
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// Software clock: advance the zero timestamp by one period whenever the host
// clock has moved past the next period boundary (standard virtual-device scheme).
static OSStatus AB_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 clientID,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inDriver; (void)clientID;
    if (!isDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    device_io_t* io = ioFor(id);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    if (ticksPerPeriod > 0) {
        Float64 elapsed = (Float64)(now - io->hostTime);
        UInt64 periods = (UInt64)(elapsed / ticksPerPeriod);
        if (periods > 0) {
            io->sampleTime += (Float64)periods * kZeroTimeStampPeriod;
            io->hostTime += (UInt64)((Float64)periods * ticksPerPeriod);
        }
    }
    *outSampleTime = io->sampleTime;
    *outHostTime = io->hostTime;
    *outSeed = io->seed;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus AB_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 clientID, UInt32 op,
                                     Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inDriver; (void)clientID;
    if (!isDevice(id)) return kAudioHardwareBadObjectError;
    Boolean mic = (id == kObjectID_MicDevice);
    *outWillDo = mic ? (op == kAudioServerPlugInIOOperationReadInput) : (op == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus AB_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)c; (void)op; (void)n; (void)i; return isDevice(id) ? 0 : kAudioHardwareBadObjectError;
}
static OSStatus AB_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)c; (void)op; (void)n; (void)i; return isDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus AB_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID id, AudioObjectID streamID, UInt32 clientID, UInt32 op,
                                 UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* mainBuf, void* secondaryBuf) {
    (void)inDriver; (void)clientID; (void)info; (void)secondaryBuf;
    if (!isDevice(id) || !isStream(streamID) || !mainBuf) return kAudioHardwareBadObjectError;
    if (id == kObjectID_WriterDevice && op == kAudioServerPlugInIOOperationWriteMix) {
        abm_fifo_push(gRing, (const float*)mainBuf, frames * kAntiBleed_Channels);
        return 0;
    }
    if (id == kObjectID_MicDevice && op == kAudioServerPlugInIOOperationReadInput) {
        Boolean writerLive = atomic_load_explicit(&gWriterIO.ioRunning, memory_order_acquire) > 0;
        if (writerLive) {
            abm_fifo_pop(gRing, (float*)mainBuf, frames * kAntiBleed_Channels);
        } else {
            // App not running: the virtual mic is silent (PLAN 15.3), never stale audio.
            memset(mainBuf, 0, frames * kAntiBleed_Channels * sizeof(float));
        }
        return 0;
    }
    return 0;
}

// -------------------------------------------------------------------- vtable + factory

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    AB_QueryInterface, AB_AddRef, AB_Release,
    AB_Initialize, AB_CreateDevice, AB_DestroyDevice, AB_AddDeviceClient, AB_RemoveDeviceClient,
    AB_PerformDeviceConfigurationChange, AB_AbortDeviceConfigurationChange,
    AB_HasProperty, AB_IsPropertySettable, AB_GetPropertyDataSize, AB_GetPropertyData, AB_SetPropertyData,
    AB_StartIO, AB_StopIO, AB_GetZeroTimeStamp, AB_WillDoIOOperation, AB_BeginIOOperation, AB_DoIOOperation, AB_EndIOOperation
};

void* AntiBleedDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}
