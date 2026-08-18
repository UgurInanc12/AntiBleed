import Foundation
import Combine

/// Phase 5: wires mic + tap -> AEC -> output. Phase 7 adds SafetyStateMachine gating.
final class AntiBleedPipeline: ObservableObject {
    @Published var state: PipelineState = .stopped

    var micCapture: MicrophoneCapture?
    var systemTap: SystemAudioTap?
    var synchronizer = AudioSynchronizer()
    var formatConverterMic = FormatConverter()
    var formatConverterRender = FormatConverter()

    // AECBridge is ObjC++ - available only on macOS; stub elsewhere
    var isAECEnabled: Bool = true

    private var dspRunning = false

    func start() throws {
        state = .bypass
        dspRunning = true
        // Start DSP thread (high priority, not main)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.dspLoop()
        }
    }

    func stop() {
        dspRunning = false
        state = .stopped
    }

    private func dspLoop() {
        while dspRunning {
            guard let pair = synchronizer.pullAlignedFrames() else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            // Phase 0-4: passthrough. Phase 5: AECBridge processRender/processCapture
            // let cleaned = aec.process(pair)
            // For now: forward mic as-is (bypass)
            _ = pair
            // Throttled stats update on main
        }
    }
}
