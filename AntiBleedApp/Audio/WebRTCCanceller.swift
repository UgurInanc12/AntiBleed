import Foundation
import AntiBleedCore
import AECBridgeC

/// EchoCanceller backed by AECBridge (WebRTC AEC3) through the C ABI.
/// Buffers are preallocated; process* never allocate (PLAN 19).
public final class WebRTCCanceller: EchoCanceller {
    private var handle: OpaquePointer?
    private var scratch: [Float]
    public let frameSize: Int

    public init?(sampleRate: Int = Int(AudioConstants.sampleRate)) {
        var cfg = abm_aec_config_t()
        abm_aec_config_default(&cfg)
        cfg.sample_rate_hz = Int32(sampleRate)
        guard let h = abm_aec_create(&cfg) else { return nil }
        handle = h
        frameSize = Int(abm_aec_frame_size(h))
        scratch = [Float](repeating: 0, count: frameSize)
    }

    deinit { if let h = handle { abm_aec_destroy(h) } }

    public var isRealAEC: Bool { handle.map { abm_aec_is_real($0) } ?? false }
    public static var engineName: String { String(cString: abm_aec_engine_name()) }

    public func processRender(_ render: [Float]) {
        guard let h = handle, render.count == frameSize else { return }
        render.withUnsafeBufferPointer { abm_aec_process_render(h, $0.baseAddress, Int32(render.count)) }
    }

    public func processCapture(_ capture: [Float]) -> [Float] {
        guard let h = handle, capture.count == frameSize else { return capture }
        capture.withUnsafeBufferPointer { src in
            scratch.withUnsafeMutableBufferPointer { dst in
                abm_aec_process_capture(h, src.baseAddress, Int32(capture.count), dst.baseAddress)
            }
        }
        return scratch
    }

    public func stats() -> AECStats {
        guard let h = handle else { return AECStats() }
        var s = abm_aec_stats_t()
        abm_aec_get_stats(h, &s)
        return AECStats(delayMs: Int(s.delay_ms),
                        delayMedianMs: Int(s.delay_median_ms),
                        delayStddevMs: Float(s.delay_stddev_ms),
                        echoReturnLoss: s.echo_return_loss,
                        echoReturnLossEnhancement: s.echo_return_loss_enhancement,
                        divergentFilterFraction: s.divergent_filter_fraction,
                        residualEchoLikelihood: s.residual_echo_likelihood,
                        valid: s.valid)
    }

    public func reset() { if let h = handle { abm_aec_reset(h) } }

    public func setDelayHint(ms: Int) { if let h = handle { abm_aec_set_delay_hint_ms(h, Int32(ms)) } }
}
