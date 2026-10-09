import Foundation

/// The app's event log — a port of the Windows `RemSoundLog` (2026-10-09, the user: "it would
/// be good to generally add proper diagnostics/logging like the RemSound windows client").
///
/// Two layers:
///
/// - **Recent events, always on, in memory** (the last `memoryDepth`). What the Diagnostics
///   screen lists and the copied report carries. Always on because the question "why did that
///   not happen?" is asked right after it did not happen — too late to switch a log on.
/// - **Log files, off by default** (as upstream's), in Application Support/Logs. Upstream's
///   tab-separated layout: a header row, `EVT` rows for events, and while the app runs a `SNAP`
///   row of counters once a second. Created lazily on the first write while enabled — switching
///   it on costs nothing until something happens — rolled to a fresh file at `rollAfterBytes`
///   (a phone left streaming for days must not grow one file without bound), and pruned at
///   start to the newest `keepFiles` (10, so at most ~100 MB) within `keepDays`.
///
/// Thread-safe: events come from the network and capture threads as well as the main actor.
/// The in-memory list is updated under a lock (cheap); file writes go to a serial queue so a
/// slow disk never stalls a packet thread. Best-effort throughout — a log that cannot be
/// written must never take the app down. Never log a password, key or fingerprint.
public final class EventLog: @unchecked Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        /// Running sequence number — a stable row identity, so a list showing these does not
        /// move the reader's place when newer entries arrive above it.
        public let id: Int
        public let date: Date
        public let message: String
    }

    public static let memoryDepth = 300
    static let keepDays: TimeInterval = 14 * 24 * 3600
    /// At most ~100 MB at the 10 MB roll — a phone should not spend more than that on logs.
    static let keepFiles = 10
    static let snapshotHeader = [
        "Kind", "Timestamp", "Device", "Running", "Receive", "Send", "Codec", "TargetMs",
        "BufferMs", "ReceivedKB", "SentKB", "Underruns", "Trims", "Peers", "Audible", "Heartbeat",
    ].joined(separator: "\t")

    private let lock = NSLock()
    private var recent: [Entry] = []
    private var count = 0
    private var fileEnabled = false

    // File state: touched only on `queue`.
    private let queue = DispatchQueue(label: "RemSound.EventLog")
    private let directory: URL
    private let deviceName: String
    private var handle: FileHandle?
    private var fileURL: URL?
    private var bytesInFile = 0
    private var creationFailed = false
    private var ordinal = 0
    /// Bytes after which the current file is closed and a fresh one started.
    let rollAfterBytes: Int

    private let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(directory: URL, deviceName: String, rollAfterBytes: Int = 10 * 1024 * 1024) {
        self.directory = directory
        self.deviceName = deviceName
        self.rollAfterBytes = rollAfterBytes
    }

    /// Application Support/Logs — inside the sandbox container on macOS, so no entitlement.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs", isDirectory: true)
    }

    // MARK: - Writing

    /// Record one event. Safe from any thread.
    public func event(_ message: String, at date: Date = Date()) {
        let clean = Self.sanitize(message)
        lock.lock()
        recent.append(Entry(id: count, date: date, message: clean))
        if recent.count > Self.memoryDepth { recent.removeFirst(recent.count - Self.memoryDepth) }
        count &+= 1
        let toFile = fileEnabled
        lock.unlock()
        guard toFile else { return }
        queue.async { [self] in
            writeLine("EVT\t\(timestamps.string(from: date))\t\(clean)")
        }
    }

    /// One `SNAP` row (fields in `snapshotHeader` order after Kind and Timestamp). Written to
    /// the file only — a counter row a second is noise in the on-screen list.
    public func snapshot(_ fields: [String], at date: Date = Date()) {
        lock.lock()
        let toFile = fileEnabled
        lock.unlock()
        guard toFile else { return }
        let row = (["SNAP", timestamps.string(from: date)] + fields.map(Self.sanitize))
            .joined(separator: "\t")
        queue.async { [self] in writeLine(row) }
    }

    public func setFileLoggingEnabled(_ enabled: Bool) {
        lock.lock()
        let changed = fileEnabled != enabled
        fileEnabled = enabled
        lock.unlock()
        guard changed, !enabled else { return }
        queue.async { [self] in
            writeRaw("EVT\t\(timestamps.string(from: Date()))\tlog stopped\n")
            closeFile()
        }
    }

    // MARK: - Reading

    /// The newest events last.
    public var recentEntries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    /// How many events have ever been recorded — lets a UI tell "changed" without comparing
    /// three hundred strings every second.
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// The file currently being written, if any.
    public var currentFile: URL? {
        queue.sync { fileURL }
    }

    /// Every log file in the folder, newest first.
    public func logFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { modified($0) > modified($1) }
    }

    /// Delete files older than `keepDays`, then all but the newest `keepFiles`. Never the one
    /// being written. Called once at start.
    public func prune(now: Date = Date()) {
        queue.async { [self] in
            let current = fileURL
            for (index, file) in logFiles().enumerated() where file != current {
                if index >= Self.keepFiles || now.timeIntervalSince(modified(file)) > Self.keepDays {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// Wait for queued file writes — tests only.
    func flushForTesting() {
        queue.sync {}
    }

    // MARK: - File plumbing (queue only)

    private func writeLine(_ line: String) {
        guard ensureFileOpen() else { return }
        writeRaw(line + "\n")
        if bytesInFile >= rollAfterBytes {
            writeRaw("EVT\t\(timestamps.string(from: Date()))\tlog reached its size cap — continuing in a fresh file\n")
            closeFile()
        }
    }

    private func writeRaw(_ text: String) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            bytesInFile += data.count
        } catch {
            // Disk full, file gone: stop trying rather than fail on every line.
            closeFile()
            creationFailed = true
        }
    }

    private func ensureFileOpen() -> Bool {
        if handle != nil { return true }
        if creationFailed { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ordinal += 1
            let stamp = Self.fileStamp.string(from: Date())
            let url = directory.appendingPathComponent(
                "RemSound-\(Self.fileSafe(deviceName))-\(stamp)-\(ordinal).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                creationFailed = true
                return false
            }
            handle = try FileHandle(forWritingTo: url)
            fileURL = url
            bytesInFile = 0
            writeRaw(Self.snapshotHeader + "\n")
            writeRaw("EVT\t\(timestamps.string(from: Date()))\tlog started\n")
            return true
        } catch {
            creationFailed = true
            return false
        }
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        // Keep `fileURL`: sharing the log right after switching it off should still work.
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Tabs and newlines would break the row layout.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func fileSafe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped.prefix(40))
    }
}
