import XCTest
@testable import AntiBleedCore

final class DiagnosticLogTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func records(_ url: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            } }
    }

    func testWritesOrderedJSONLWithSessionAndPrivacyRedaction() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir)
        log.record("start", fields: ["error": NSHomeDirectory() + "/Downloads/app failed", "level": "-inf"])
        log.record("problem_marker")
        log.flush()
        let rows = try records(dir)
        XCTAssertEqual(rows.map { $0["event"] as? String }, ["start", "problem_marker"])
        XCTAssertEqual(rows[0]["session"] as? String, log.sessionID)
        XCTAssertNotNil(rows[0]["timestamp"])
        let fields = rows[0]["fields"] as! [String: String]
        XCTAssertFalse(fields["error"]!.contains(NSHomeDirectory()))
        XCTAssertEqual(fields["level"], "-inf")
        XCTAssertEqual(log.status.written, 2)
    }

    func testDisableFlushesMarkerAndRejectsFurtherRecords() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir)
        log.record("start")
        log.setEnabled(false)
        XCTAssertFalse(log.record("must_not_exist"))
        log.flush()
        XCTAssertEqual(try records(dir).map { $0["event"] as? String }, ["start", "logging_disabled"])
        log.setEnabled(true)
        log.record("resumed")
        log.flush()
        XCTAssertEqual(try records(dir).last?["event"] as? String, "resumed")
    }

    func testRotationBoundsDiskAndRecordsRetentionLoss() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 1024, maxFiles: 3)
        for i in 0..<80 { log.record("event", fields: ["index": "\(i)", "value": String(repeating: "x", count: 200)]); log.flush() }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 3)
        for file in files { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 1024) }
        XCTAssertGreaterThan(log.status.prunedFiles, 0)
        XCTAssertGreaterThan((try records(dir).last?["pruned_files"] as? Int) ?? 0, 0)
    }

    func testDiskFailureIsVisibleAndDoesNotThrowIntoCaller() throws {
        let file = directory(); defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)
        let log = DiagnosticLog(directory: file)
        log.record("event"); log.flush()
        XCTAssertNotNil(log.status.error)
        XCTAssertEqual(log.status.written, 0)
        XCTAssertGreaterThan(log.status.dropped, 0)
    }

    func testOversizedRecordIsRejectedAndCounted() {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 512)
        log.record("huge", fields: ["value": String(repeating: "x", count: 20_000)])
        log.flush()
        XCTAssertEqual(log.status.written, 0)
        XCTAssertEqual(log.status.dropped, 1)
    }

    func testExportCreatesConsistentSnapshotWithManifest() throws {
        let dir = directory(), export = directory()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: export) }
        let log = DiagnosticLog(directory: dir)
        log.record("before_export")
        let done = expectation(description: "export")
        log.exportSnapshot(to: export) { result in
            switch result {
            case .success(let url):
                XCTAssertEqual(url, export)
                XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("manifest.json").path))
            case .failure(let error): XCTFail("\(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try records(export).first?["event"] as? String, "before_export")
    }

    func testPerRecordLimitBoundsPendingMemoryIndependentlyOfFileSize() {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir)
        XCTAssertFalse(log.record("large", fields: ["text": String(repeating: "x", count: 100_000)]))
        log.flush()
        XCTAssertEqual(log.status.dropped, 1)
    }

    func testBackpressureDropsLogsRatherThanBlockingCaller() throws {
        let dir = directory(), export = directory()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: export) }
        let log = DiagnosticLog(directory: dir, maxPending: 2)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        log.exportSnapshot(to: export) { _ in entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for _ in 0..<100 { log.record("event") }
        XCTAssertEqual(log.status.dropped, 98)
        release.signal()
        log.flush()
        XCTAssertEqual(log.status.written, 2)
        XCTAssertEqual(try records(dir).last?["dropped_records"] as? Int, 98)
    }

    func testEightHoursOfSummaryVolumeStaysBounded() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir, maxFileBytes: 32_768, maxFiles: 3)
        for second in 0..<28_800 {
            log.record("health_summary", fields: ["simulated_second": String(second), "frames.delta": "100"])
            if second % 64 == 0 { log.flush() }
        }
        log.flush()
        XCTAssertEqual(log.status.written, 28_800)
        XCTAssertEqual(log.status.dropped, 0)
        XCTAssertGreaterThan(log.status.prunedFiles, 0)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        XCTAssertLessThanOrEqual(size, 3 * 32_768)
        XCTAssertEqual((try records(dir).last?["fields"] as? [String: String])?["simulated_second"], "28799")
    }

    func testTransitionReasonIsCapturedAtDecisionTime() {
        let fsm = SafetyStateMachine()
        fsm.start()
        XCTAssertEqual(fsm.lastTransitionReason, "start")
        _ = fsm.update(renderActivity: RenderActivity(isActive: true),
                       coupling: CouplingResult(score: 0.9, stableWindows: 8), aecStats: AECStats())
        XCTAssertEqual(fsm.lastTransitionReason, "render_active")
        _ = fsm.update(renderActivity: RenderActivity(isActive: true),
                       coupling: CouplingResult(score: 0.9, stableWindows: 8), aecStats: AECStats(), aecAvailable: false)
        XCTAssertEqual(fsm.lastTransitionReason, "aec_unavailable")
    }

    func testHealthSummaryPreservesExtremaAndCounterReset() {
        var health = DiagnosticHealthWindow()
        health.observe(metrics: ["raw_db": -40], counters: ["frames": 100, "drops": 2])
        health.observe(metrics: ["raw_db": -8], counters: ["frames": 150, "drops": 5])
        let first = health.finish()
        XCTAssertEqual(first["raw_db.min"], "-40.0")
        XCTAssertEqual(first["raw_db.max"], "-8.0")
        XCTAssertEqual(first["drops.delta"], "3")
        health.observe(metrics: ["raw_db": -.infinity], counters: ["frames": 10, "drops": 0])
        let second = health.finish()
        XCTAssertEqual(second["frames.reset"], "true")
        XCTAssertEqual(second["raw_db.nonfinite"], "1")
    }
}
