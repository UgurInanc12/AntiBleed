import Foundation
import AntiBleedCore
#if canImport(CoreAudio)
import CoreAudio
#endif

public struct AudioDevice: Identifiable, Equatable, Hashable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var isInput: Bool
    public var isOutput: Bool
    public var sampleRate: Double
    public var inputChannels: UInt32
    public var outputChannels: UInt32
    public var transportType: UInt32 = 0
    public var isHidden: Bool = false
}

/// Device enumeration and change observation (PLAN 24, Phase 1/2).
/// Anti-Bleed's own virtual devices are filtered out of the pickers so a user
/// cannot route the virtual mic into itself.
public final class DeviceManager: ObservableObject {
    public static let virtualMicUID = "com.antibleed.mic"
    public static let virtualWriterUID = "com.antibleed.writer"

    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var outputDevices: [AudioDevice] = []
    @Published public private(set) var defaultInputUID: String?
    @Published public private(set) var defaultOutputUID: String?
    @Published public private(set) var virtualMicPresent = false
    @Published public private(set) var virtualWriterPresent = false

    /// Fired after every refresh caused by a hardware change. UI and pipeline
    /// subscribe to re-resolve selected UIDs (IDs are not stable across reboots).
    public var onDevicesChanged: (() -> Void)?

    public init() {}

    public func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return (inputDevices + outputDevices).first { $0.uid == uid }
    }

#if canImport(CoreAudio)
    private var listenerInstalled = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = CoreAudioProperty.getArray(system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        var inputs: [AudioDevice] = [], outputs: [AudioDevice] = []
        var micPresent = false, writerPresent = false
        for id in ids {
            guard let uid = CoreAudioProperty.getString(id, kAudioDevicePropertyDeviceUID) else { continue }
            let name = CoreAudioProperty.getString(id, kAudioObjectPropertyName) ?? uid
            let inCh = CoreAudioProperty.channelCount(id, scope: kAudioDevicePropertyScopeInput)
            let outCh = CoreAudioProperty.channelCount(id, scope: kAudioDevicePropertyScopeOutput)
            let rate = CoreAudioProperty.get(id, kAudioDevicePropertyNominalSampleRate, default: Double(0))
            let transport = CoreAudioProperty.get(id, kAudioDevicePropertyTransportType, default: UInt32(0))
            let hidden = CoreAudioProperty.get(id, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0
            let dev = AudioDevice(id: id, uid: uid, name: name, isInput: inCh > 0, isOutput: outCh > 0,
                                  sampleRate: rate, inputChannels: inCh, outputChannels: outCh,
                                  transportType: transport, isHidden: hidden)
            if uid == Self.virtualMicUID { micPresent = true; continue }
            if uid == Self.virtualWriterUID { writerPresent = true; continue }
            if hidden { continue }
            // Aggregate devices created by us are private and never enumerate here.
            if dev.isInput { inputs.append(dev) }
            if dev.isOutput { outputs.append(dev) }
        }
        let defIn = CoreAudioProperty.get(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
        let defOut = CoreAudioProperty.get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
        DispatchQueue.main.async {
            self.inputDevices = inputs.sorted { $0.name < $1.name }
            self.outputDevices = outputs.sorted { $0.name < $1.name }
            self.defaultInputUID = inputs.first { $0.id == defIn }?.uid
            self.defaultOutputUID = outputs.first { $0.id == defOut }?.uid
            self.virtualMicPresent = micPresent
            self.virtualWriterPresent = writerPresent
            self.onDevicesChanged?()
        }
    }

    public func observeDeviceChanges() {
        guard !listenerInstalled else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = CoreAudioProperty.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.global(qos: .utility), block)
        }
        listenerInstalled = true
    }
#else
    public func refresh() { onDevicesChanged?() }
    public func observeDeviceChanges() {}
#endif
}
