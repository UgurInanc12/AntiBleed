import Foundation

/// Metadata only. Call from the control/telemetry path, NEVER an audio callback.
/// Disk work is serialized separately and the pending queue is bounded.
public final class DiagnosticLog: @unchecked Sendable {
    public struct Status: Equatable {
        public var enabled = true
        public var written: UInt64 = 0
        public var dropped: UInt64 = 0
        public var prunedFiles: UInt64 = 0
        public var error: String?
        public init() {}
    }

    public let sessionID = UUID().uuidString
    public let directory: URL
    private let queue = DispatchQueue(label: "AntiBleed.LogWriter", qos: .utility)
    private let lock = NSLock()
    private var state = Status()
    private var pending = 0
    private let maxPending: Int
    private let maxFileBytes: Int
    private let maxFiles: Int
    private var file: FileHandle?
    private var fileBytes = 0
    private var segment = 0
    private let prefix: String
    private let started = ProcessInfo.processInfo.systemUptime

    public init(directory: URL, maxFileBytes: Int = 5 * 1024 * 1024,
                maxFiles: Int = 20, maxPending: Int = 256, enabled: Bool = true) {
        self.directory = directory
        self.maxFileBytes = max(512, maxFileBytes)
        self.maxFiles = max(1, maxFiles)
        self.maxPending = max(1, maxPending)
        state.enabled = enabled
        prefix = "abm-\(Int64(Date().timeIntervalSince1970 * 1000))-\(sessionID)"
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    @discardableResult
    public func record(_ event: String, fields: [String: String] = [:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.enabled else { return false }
        return enqueue(event, fields: fields)
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard state.enabled != enabled else { return }
        state.enabled = enabled
        _ = enqueue(enabled ? "logging_enabled" : "logging_disabled", fields: [:])
    }

    // Caller holds lock; enqueue order follows event/enable order.
    private func enqueue(_ event: String, fields: [String: String]) -> Bool {
        guard pending < maxPending, event.utf8.count <= 128, fields.count <= 128,
              fields.reduce(event.utf8.count, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= min(maxFileBytes, 16 * 1024) else {
            state.dropped += 1
            return false
        }
        pending += 1
        let timestamp = Date()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                var safe: [String: String] = [:]
                for (key, value) in fields { safe[key] = redact(value) }
                // Rotate before encoding so this record includes current retention counters.
                var data = try encode(event, fields: safe, date: timestamp, elapsed: elapsed)
                if file == nil || fileBytes + data.count > maxFileBytes {
                    try rotate()
                    data = try encode(event, fields: safe, date: timestamp, elapsed: elapsed)
                }
                guard data.count <= maxFileBytes else {
                    lock.lock(); state.dropped += 1; lock.unlock()
                    return
                }
                try file?.write(contentsOf: data)
                fileBytes += data.count
                lock.lock(); state.written += 1; state.error = nil; lock.unlock()
            } catch {
                try? file?.close(); file = nil
                lock.lock()
                state.dropped += 1
                state.error = "Log write failed (\((error as NSError).domain):\((error as NSError).code))"
                lock.unlock()
            }
        }
        return true
    }

    private func redact(_ value: String) -> String {
        var result = value.replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        // Device names can contain an account name; do not export that name verbatim.
        for name in [NSUserName(), NSFullUserName()] where !name.isEmpty {
            result = result.replacingOccurrences(of: name, with: "<user>", options: .caseInsensitive)
        }
        return result.replacingOccurrences(of: #"(?:/Users/|[A-Za-z]:[\\/]Users[\\/])[^/\\\s]+"#,
                                           with: "<home>", options: .regularExpression)
    }

    private func encode(_ event: String, fields: [String: String], date: Date, elapsed: Double) throws -> Data {
        let current = status
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = ["schema": 1, "session": sessionID, "event": event,
                                  "timestamp": formatter.string(from: date), "elapsed_seconds": elapsed,
                                  "dropped_records": current.dropped, "pruned_files": current.prunedFiles,
                                  "fields": fields]
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func logFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("abm-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func rotate() throws {
        try file?.close(); file = nil
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let files = try logFiles()
        for old in files.prefix(max(0, files.count - maxFiles + 1)) {
            try fm.removeItem(at: old)
            lock.lock(); state.prunedFiles += 1; lock.unlock()
        }
        segment += 1
        let url = directory.appendingPathComponent(String(format: "%@-%06d.jsonl", prefix, segment))
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
        fileBytes = 0
    }

    /// For orderly shutdown/tests, never call on an audio worker.
    public func flush() {
        queue.sync {
            do { try file?.synchronize() }
            catch {
                lock.lock(); state.error = "Log flush failed"; lock.unlock()
            }
        }
    }

    /// Copies a consistent retained-log snapshot on the writer queue.
    /// The UI packages this directory; live logs are never zipped while changing.
    public func exportSnapshot(to destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            do {
                try file?.synchronize()
                let fm = FileManager.default
                guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                do {
                    if fm.fileExists(atPath: directory.path) {
                        for source in try logFiles() {
                            try fm.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent))
                        }
                    }
                    let current = status
                    let manifest: [String: Any] = ["schema": 1, "session": sessionID,
                        "audio_recorded": false, "dropped_records": current.dropped,
                        "pruned_files": current.prunedFiles, "max_files": maxFiles,
                        "max_file_bytes": maxFileBytes, "writer_error": current.error ?? "none"]
                    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                        .write(to: destination.appendingPathComponent("manifest.json"))
                    completion(.success(destination))
                } catch {
                    try? fm.removeItem(at: destination)
                    throw error
                }
            } catch { completion(.failure(error)) }
        }
    }

    deinit { try? file?.close() }
}

/// Extrema over observed telemetry samples, plus counter deltas across windows.
/// This does not claim sample-accurate audio extrema between telemetry polls.
public struct DiagnosticHealthWindow {
    private var samples = 0
    private var metrics: [String: (min: Double, max: Double, last: Double, nonfinite: Int)] = [:]
    private var previous: [String: UInt64] = [:]
    private var deltas: [String: UInt64] = [:]
    private var resets: Set<String> = []
    public init() {}

    public mutating func observe(metrics values: [String: Double], counters: [String: UInt64]) {
        samples += 1
        for (key, value) in values {
            var item = metrics[key] ?? (.infinity, -.infinity, value, 0)
            item.last = value
            if value.isFinite { item.min = min(item.min, value); item.max = max(item.max, value) }
            else { item.nonfinite += 1 }
            metrics[key] = item
        }
        for (key, value) in counters {
            if let old = previous[key] {
                if value < old { resets.insert(key) }
                deltas[key, default: 0] += value >= old ? value - old : value
            }
            previous[key] = value
        }
    }

    public mutating func finish() -> [String: String] {
        var fields = ["telemetry_samples": String(samples)]
        for (key, item) in metrics {
            fields[key + ".min"] = String(item.min)
            fields[key + ".max"] = String(item.max)
            fields[key + ".last"] = String(item.last)
            fields[key + ".nonfinite"] = String(item.nonfinite)
        }
        for (key, value) in previous {
            fields[key + ".total"] = String(value)
            fields[key + ".delta"] = String(deltas[key, default: 0])
            if resets.contains(key) { fields[key + ".reset"] = "true" }
        }
        samples = 0; metrics.removeAll(keepingCapacity: true)
        deltas.removeAll(keepingCapacity: true); resets.removeAll(keepingCapacity: true)
        return fields
    }
}
