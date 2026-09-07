#if canImport(CoreAudio)
import Foundation
import CoreAudio
import AudioToolbox

/// Thin, typed wrappers around AudioObjectGetPropertyData / SetPropertyData.
/// All calls are for the control path; never call these from an IOProc.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        return AudioObjectHasProperty(object, &addr)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       default value: T) -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out)
        return err == noErr ? out : value
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>? = nil
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            of: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        var buffer = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &buffer)
        return err == noErr ? Array(buffer.prefix(Int(size) / MemoryLayout<T>.size)) : []
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       value: T) -> OSStatus {
        var addr = address(selector, scope: scope)
        var v = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    /// Number of channels on the given scope (input or output) of a device.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cf) { cfPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), cfPtr, &size, &out)
        }
        return (err == noErr && out != kAudioObjectUnknown) ? out : nil
    }
}

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let context: String
    var errorDescription: String? { "\(context) failed (OSStatus \(status))" }
}
#endif
