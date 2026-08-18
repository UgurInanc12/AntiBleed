import SwiftUI
import Combine

enum PipelineState: String {
    case stopped = "Stopped"
    case bypass = "Bypass"
    case probing = "Probing"
    case learning = "Learning"
    case active = "Active"
    case degraded = "Degraded"
    case error = "Error"
}

struct Meters {
    var rawMicRmsDb: Float = -.infinity
    var renderRmsDb: Float = -.infinity
    var cleanedRmsDb: Float = -.infinity
}

struct AECStatsSnapshot {
    var delayMs: Int = -1
    var delayMedianMs: Int = -1
    var delayStddevMs: Int = -1
    var echoReturnLoss: Float = 0
    var echoReturnLossEnhancement: Float = 0
    var divergentFilterFraction: Float = 0
}

struct DiagnosticsSnapshot {
    var selectedMicName: String = "-"
    var selectedOutputName: String = "-"
    var tapStatus: String = "NotCreated"
    var driverVersion: String = "-"
    var appVersion: String = "-"
    var sampleRates: String = "-"
    var queueDepths: String = "-"
    var overruns: UInt64 = 0
    var underruns: UInt64 = 0
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedMicUID: String?
    @Published var selectedOutputUID: String?
    @Published var pipelineState: PipelineState = .stopped
    @Published var isAECEnabled: Bool = true
    @Published var meters: Meters = Meters()
    @Published var aecStats: AECStatsSnapshot = AECStatsSnapshot()
    @Published var diagnostics: DiagnosticsSnapshot = DiagnosticsSnapshot()
    @Published var permissions: Permissions = Permissions()

    var deviceManager: DeviceManager = DeviceManager()
    var pipeline: AntiBleedPipeline?

    init() {}

    func startPipeline() {
        // Phase 1-3: pipeline wiring happens incrementally
        pipelineState = .bypass
    }

    func stopPipeline() {
        pipeline?.stop()
        pipelineState = .stopped
    }
}
