#if canImport(CoreAudio)
import Foundation
import CoreAudio
import AudioToolbox
import AntiBleedCore
import AntiBleedRealtime

/// Captures the selected physical microphone AND the system-output reference in
/// ONE private aggregate device (PLAN 11, D-003, D-011):
///
///   aggregate = [ mic sub-device ] + [ process tap on the selected output ]
///
/// Because both live in the same aggregate, Core Audio delivers them in the
/// same IOProc call with a shared clock, so the mic block and the render block
/// of a callback are already time-aligned. The IOProc only copies into the
/// lock-free ring (PLAN 19); all DSP happens on the worker thread.
///
/// The tap is private, unmuted (speakers keep playing) and excludes our own
/// process so Anti-Bleed's writer output never re-enters the reference.
@available(macOS 14.2, *)
public final class AggregateCapture {
    public enum State: String { case idle, creating, running, stopped, failed }

    public private(set) var state: State = .idle
    public private(set) var lastError: String?
    public private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var micChannels = 0
    public private(set) var tapChannels = 0
    public private(set) var sampleRate: Double = 0
    public let ring: OpaquePointer // abm_ring_t*

    private var ioProcID: AudioDeviceIOProcID?
    private let aggregateUID = "com.antibleed.aggregate." + UUID().uuidString
    private var micDeviceUID = ""
    private var micChannelOffset = 0
    private var tapChannelOffset = 0
    private var timebaseInfo = mach_timebase_info_data_t()
    // Preallocated mono staging (max callback size); never resized in the IOProc.
    private var micMono: UnsafeMutablePointer<Float>
    private var renderMono: UnsafeMutablePointer<Float>
    private let maxFrames: Int

    public init(maxCallbackFrames: Int = 4096, ringSlots: Int = 64) {
        maxFrames = maxCallbackFrames
        ring = abm_ring_create(UInt32(ringSlots), UInt32(maxCallbackFrames))!
        micMono = .allocate(capacity: maxCallbackFrames)
        renderMono = .allocate(capacity: maxCallbackFrames)
        micMono.initialize(repeating: 0, count: maxCallbackFrames)
        renderMono.initialize(repeating: 0, count: maxCallbackFrames)
        mach_timebase_info(&timebaseInfo)
    }

    deinit {
        stop()
        destroy()
        abm_ring_destroy(ring)
        micMono.deallocate()
        renderMono.deallocate()
    }

    /// Builds the tap + aggregate for the given devices. `outputDeviceUID == nil`
    /// means "no reference" (headphones-only mode): the render channel stays silent
    /// and the FSM will never leave BYPASS.
    public func create(micDeviceUID: String, outputDeviceUID: String?) throws {
        destroy()
        state = .creating
        self.micDeviceUID = micDeviceUID

        guard let micID = CoreAudioProperty.deviceID(forUID: micDeviceUID) else {
            state = .failed; lastError = "Microphone \(micDeviceUID) not found"
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "resolve mic UID")
        }
        micChannels = Int(CoreAudioProperty.channelCount(micID, scope: kAudioDevicePropertyScopeInput))

        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: micDeviceUID]]
        var tapList: [[String: Any]] = []

        if let outUID = outputDeviceUID {
            // Tap on the selected physical output, excluding ourselves. Stereo mixdown,
            // unmuted (the user keeps hearing their speakers), private (invisible to
            // other apps and to device pickers).
            // Device-scoped tap on the selected physical output, excluding our own
            // process (isExclusive = true semantics: everything EXCEPT the listed
            // processes) so the writer's audio never re-enters the reference.
            let excluded: [AudioObjectID] = ownProcessObjectID().map { [$0] } ?? []
            // Swift import of -[CATapDescription initExcludingProcesses:andDeviceUID:withStream:]
            // is init(processes:deviceUID:stream:) with isExclusive = true.
            let desc = CATapDescription(processes: excluded, deviceUID: outUID, stream: 0)
            desc.isExclusive = true        // capture everything EXCEPT the listed processes
            desc.name = "Anti-Bleed reference tap"
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior.unmuted   // speakers keep playing
            desc.isMixdown = true          // stereo mixdown of the output
            desc.isMono = false
            var newTap = AudioObjectID(kAudioObjectUnknown)
            let err = AudioHardwareCreateProcessTap(desc, &newTap)
            guard err == noErr, newTap != kAudioObjectUnknown else {
                state = .failed; lastError = "AudioHardwareCreateProcessTap failed: \(err)"
                throw CoreAudioError(status: err, context: "AudioHardwareCreateProcessTap")
            }
            tapID = newTap
            tapChannels = 2
            // The aggregate references the tap by its UID as reported by the HAL.
            let tapUID = CoreAudioProperty.getString(newTap, kAudioTapPropertyUID) ?? desc.uuid.uuidString
            tapList = [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        } else {
            tapChannels = 0
        }

        // Clocking: an aggregate's clock comes from its main sub-device; a tap cannot be
        // main. The mic is therefore the clock (not drift compensated) and the tap is
        // drift compensated onto it. Either way both arrive in one IOProc, time-aligned.
        subDevices[0][kAudioSubDeviceDriftCompensationKey] = false

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Anti-Bleed capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: micDeviceUID,
        ]
        if !tapList.isEmpty {
            description[kAudioAggregateDeviceTapListKey] = tapList
            description[kAudioAggregateDeviceTapAutoStartKey] = true
        }

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr, aggID != kAudioObjectUnknown else {
            state = .failed; lastError = "AudioHardwareCreateAggregateDevice failed: \(err)"
            destroyTap()
            throw CoreAudioError(status: err, context: "AudioHardwareCreateAggregateDevice")
        }
        aggregateID = aggID

        // Canonical rate. If the device refuses 48 kHz we keep its rate and let
        // FrameAssembler resample.
        CoreAudioProperty.set(aggID, kAudioDevicePropertyNominalSampleRate, value: AudioConstants.sampleRate)
        sampleRate = CoreAudioProperty.get(aggID, kAudioDevicePropertyNominalSampleRate, default: AudioConstants.sampleRate)

        // Input channel layout of the aggregate: sub-devices first (in list order),
        // then taps. Mic channels occupy [0, micChannels), tap channels follow.
        micChannelOffset = 0
        tapChannelOffset = micChannels

        // Keep callbacks small for latency (PLAN 30): ask for 256 frames (~5.3 ms).
        CoreAudioProperty.set(aggID, kAudioDevicePropertyBufferFrameSize, value: UInt32(256))
        state = .stopped
    }

    public func start() throws {
        guard aggregateID != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "start without aggregate")
        }
        if ioProcID != nil { return }
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] inNow, inInputData, inInputTime, _, _ in
            self.handleIO(now: inNow, input: inInputData, inputTime: inInputTime)
        }
        guard err == noErr, let procID else {
            state = .failed; lastError = "AudioDeviceCreateIOProcIDWithBlock failed: \(err)"
            throw CoreAudioError(status: err, context: "AudioDeviceCreateIOProcIDWithBlock")
        }
        ioProcID = procID
        let startErr = AudioDeviceStart(aggregateID, procID)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            state = .failed; lastError = "AudioDeviceStart failed: \(startErr)"
            throw CoreAudioError(status: startErr, context: "AudioDeviceStart")
        }
        state = .running
    }

    public func stop() {
        guard aggregateID != kAudioObjectUnknown, let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
        if state == .running { state = .stopped }
    }

    public func destroy() {
        stop()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        destroyTap()
        abm_ring_reset(ring)
        state = .idle
    }

    private func destroyTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Real-time path (PLAN 19: copy, timestamp, push, return)

    private func handleIO(now: UnsafePointer<AudioTimeStamp>,
                          input: UnsafePointer<AudioBufferList>,
                          inputTime: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = abl.first, first.mDataByteSize > 0 else { return }
        // The aggregate vends interleaved or per-channel buffers depending on the
        // device. Handle both: compute channel c, frame i.
        let totalChannels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard totalChannels >= micChannels + tapChannels, micChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        guard frames > 0, frames <= maxFrames else { return }

        // Downmix mic channels -> mono, tap channels -> mono.
        for i in 0..<frames { micMono[i] = 0; renderMono[i] = 0 }
        var channelBase = 0
        for buf in abl {
            let ch = Int(buf.mNumberChannels)
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { channelBase += ch; continue }
            for c in 0..<ch {
                let globalChannel = channelBase + c
                let isMic = globalChannel >= micChannelOffset && globalChannel < micChannelOffset + micChannels
                let isTap = tapChannels > 0 && globalChannel >= tapChannelOffset && globalChannel < tapChannelOffset + tapChannels
                if !isMic && !isTap { continue }
                let target = isMic ? micMono : renderMono
                let scale: Float = isMic ? 1 / Float(micChannels) : 1 / Float(tapChannels)
                var idx = c
                for i in 0..<frames {
                    target[i] += data[idx] * scale
                    idx += ch
                }
            }
            channelBase += ch
        }

        let ts = inputTime.pointee
        let hostNs = hostTimeToNanos(ts.mHostTime)
        _ = abm_ring_push(ring, micMono, tapChannels > 0 ? renderMono : nil, UInt32(frames),
                          hostNs, ts.mSampleTime, ts.mRateScalar)
    }

    private func hostTimeToNanos(_ host: UInt64) -> UInt64 {
        if timebaseInfo.denom == 0 { return host }
        return host &* UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    private func ownProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &out)
        return (err == noErr && out != kAudioObjectUnknown) ? out : nil
    }
}
#endif
