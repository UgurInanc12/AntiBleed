#if canImport(CoreAudio)
import Foundation
import CoreAudio
import AudioToolbox
import AntiBleedCore
import AntiBleedRealtime

/// Feeds the cleaned (or raw, when bypassed) mono PCM into the hidden
/// `Anti-Bleed_internal_writer` output device of AntiBleed.driver (D-005).
/// The driver copies it into its shared ring and vends it as the visible
/// `Anti-Bleed_mic` input that Discord/Zoom select.
///
/// DSP thread -> abm_fifo (lock-free) -> writer IOProc -> driver.
/// Underflow -> writer emits silence (never replays), counted for diagnostics.
@available(macOS 14.2, *)
public final class VirtualMicWriter {
    public enum State: String { case unresolved, resolved, running, stopped, failed }
    public static let writerUID = DeviceManager.virtualWriterUID

    public private(set) var state: State = .unresolved
    public private(set) var deviceID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var lastError: String?
    public private(set) var outputChannels = 1
    public private(set) var sampleRate: Double = 0
    public var underruns: UInt64 { abm_fifo_underruns(fifo) }
    public var overruns: UInt64 { abm_fifo_overruns(fifo) }
    public var queuedSamples: Int { Int(abm_fifo_available(fifo)) }

    private let fifo: OpaquePointer // abm_fifo_t*
    private var ioProcID: AudioDeviceIOProcID?
    private var scratch: UnsafeMutablePointer<Float>
    private let maxFrames: Int

    /// `depthFrames` bounds added latency: 10 frames = 100 ms worst case, typical fill ~2-3 frames.
    public init(depthFrames: Int = 10, maxCallbackFrames: Int = 4096) {
        fifo = abm_fifo_create(UInt32(depthFrames * AudioConstants.frameSize))!
        maxFrames = maxCallbackFrames
        scratch = .allocate(capacity: maxCallbackFrames)
        scratch.initialize(repeating: 0, count: maxCallbackFrames)
    }

    deinit {
        stop()
        abm_fifo_destroy(fifo)
        scratch.deallocate()
    }

    /// Locates the hidden writer by UID and verifies it really is hidden + output-only.
    public func resolve() throws {
        stop()
        lastError = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        guard let id = CoreAudioProperty.deviceID(forUID: Self.writerUID) else {
            state = .unresolved
            lastError = "AntiBleed.driver not installed (writer UID \(Self.writerUID) not found)"
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "resolve writer UID")
        }
        let hidden = CoreAudioProperty.get(id, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0
        let outCh = Int(CoreAudioProperty.channelCount(id, scope: kAudioDevicePropertyScopeOutput))
        guard outCh > 0 else {
            state = .failed; lastError = "writer has no output channels"
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "writer channels")
        }
        if !hidden {
            // Not fatal, but it means the driver bundle is stale. Surface it.
            lastError = "writer device is not hidden; update AntiBleed.driver"
        }
        deviceID = id
        outputChannels = outCh
        CoreAudioProperty.set(id, kAudioDevicePropertyNominalSampleRate, value: AudioConstants.sampleRate)
        sampleRate = CoreAudioProperty.get(id, kAudioDevicePropertyNominalSampleRate, default: AudioConstants.sampleRate)
        state = .resolved
    }

    public var isResolved: Bool { state == .resolved || state == .running }

    public func start() throws {
        guard deviceID != kAudioObjectUnknown else { throw CoreAudioError(status: kAudioHardwareBadDeviceError, context: "writer start unresolved") }
        if ioProcID != nil { return }
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [unowned self] _, _, _, outOutputData, _ in
            self.render(into: outOutputData)
        }
        guard err == noErr, let procID else {
            state = .failed; lastError = "writer IOProc creation failed: \(err)"
            throw CoreAudioError(status: err, context: "AudioDeviceCreateIOProcIDWithBlock(writer)")
        }
        ioProcID = procID
        let s = AudioDeviceStart(deviceID, procID)
        guard s == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID); ioProcID = nil
            state = .failed; lastError = "writer AudioDeviceStart failed: \(s)"
            throw CoreAudioError(status: s, context: "AudioDeviceStart(writer)")
        }
        state = .running
    }

    public func stop() {
        guard deviceID != kAudioObjectUnknown, let procID = ioProcID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        ioProcID = nil
        abm_fifo_reset(fifo)
        state = .stopped
    }

    /// Called from the DSP worker with the frame selected by the safety FSM.
    public func write(_ frame: AudioFrame) {
        frame.samples.withUnsafeBufferPointer { p in
            _ = abm_fifo_push(fifo, p.baseAddress, UInt32(p.count))
        }
    }

    // MARK: - Real-time path

    private func render(into output: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(output)
        for buf in abl {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(buf.mNumberChannels)
            let frames = Int(buf.mDataByteSize) / (max(1, ch) * MemoryLayout<Float>.size)
            guard frames > 0 else { continue }
            let n = min(frames, maxFrames)
            _ = abm_fifo_pop(fifo, scratch, UInt32(n))
            if ch == 1 {
                data.update(from: scratch, count: n)
            } else {
                var idx = 0
                for i in 0..<n {
                    for _ in 0..<ch { data[idx] = scratch[i]; idx += 1 }
                }
            }
            if frames > n {
                // Should never happen with maxFrames = 4096; fill the rest with silence.
                for i in (n * ch)..<(frames * ch) { data[i] = 0 }
            }
        }
    }
}
#endif
