@testable import RemSoundKit
import XCTest

/// Pins the event log (`EventLog`, a port of the Windows `RemSoundLog`). Upstream's lesson,
/// 2026-08-24: "we have spent months and months building logs on top of logs … but we've
/// never tested those logs" — a log nobody tested is one you find empty the night you need it.
final class EventLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLog(rollAfterBytes: Int = 10 * 1024 * 1024) -> EventLog {
        EventLog(directory: directory, deviceName: "Test iPhone", rollAfterBytes: rollAfterBytes)
    }

    private func contents(_ url: URL?) throws -> String {
        try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
    }

    func testRecentEventsAreKeptInOrderAndCapped() {
        let log = makeLog()
        for i in 0..<(EventLog.memoryDepth + 10) { log.event("event \(i)") }
        let recent = log.recentEntries
        XCTAssertEqual(recent.count, EventLog.memoryDepth)
        XCTAssertEqual(recent.first?.message, "event 10", "the oldest fall off")
        XCTAssertEqual(recent.last?.message, "event \(EventLog.memoryDepth + 9)")
        XCTAssertEqual(log.eventCount, EventLog.memoryDepth + 10)
        // Ids keep counting past the cap, so a list keyed on them never reuses one.
        XCTAssertEqual(recent.last?.id, EventLog.memoryDepth + 9)
    }

    func testTabsAndNewlinesCannotBreakARow() {
        let log = makeLog()
        log.event("a\tb\nc\rd")
        XCTAssertEqual(log.recentEntries.last?.message, "a b c d")
    }

    /// Off by default, like upstream's: no folder, no file, nothing written — while the
    /// in-memory list still works, because "why did that not happen?" is asked afterwards.
    func testNothingTouchesTheDiskWhileFilesAreOff() {
        let log = makeLog()
        log.event("hello")
        log.snapshot(["x"])
        log.flushForTesting()
        XCTAssertNil(log.currentFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(log.recentEntries.map(\.message), ["hello"])
    }

    func testAFileGetsTheHeaderEventsAndSnapshots() throws {
        let log = makeLog()
        log.setFileLoggingEnabled(true)
        log.event("receive audio on")
        log.snapshot(["Test iPhone", "true", "true", "false"])
        log.flushForTesting()

        let file = try XCTUnwrap(log.currentFile)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("RemSound-Test_iPhone-"))
        XCTAssertEqual(file.pathExtension, "log")
        let lines = try contents(file).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, EventLog.snapshotHeader)
        XCTAssertTrue(lines.contains { $0.hasPrefix("EVT\t") && $0.hasSuffix("\tlog started") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("EVT\t") && $0.hasSuffix("\treceive audio on") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("SNAP\t") && $0.hasSuffix("\tTest iPhone\ttrue\ttrue\tfalse") })
    }

    /// Snapshots are for the file only: a row of counters a second would drown the list.
    func testSnapshotsStayOutOfTheOnScreenList() {
        let log = makeLog()
        log.setFileLoggingEnabled(true)
        log.snapshot(["counters"])
        XCTAssertTrue(log.recentEntries.isEmpty)
    }

    func testSwitchingFilesOffSaysSoAndKeepsTheFileForSharing() throws {
        let log = makeLog()
        log.setFileLoggingEnabled(true)
        log.event("one")
        log.setFileLoggingEnabled(false)
        log.event("two")
        log.flushForTesting()

        let text = try contents(log.currentFile)
        XCTAssertTrue(text.contains("\tone\n"))
        XCTAssertTrue(text.contains("\tlog stopped\n"))
        XCTAssertFalse(text.contains("\ttwo\n"), "nothing is written after the switch goes off")
    }

    /// A phone left streaming for days must not grow one file without bound.
    func testTheFileRollsAtItsSizeCap() throws {
        let log = makeLog(rollAfterBytes: 400)
        log.setFileLoggingEnabled(true)
        for i in 0..<20 { log.event("a fairly ordinary event line number \(i)") }
        log.flushForTesting()

        let files = log.logFiles()
        XCTAssertGreaterThan(files.count, 1)
        let all = try files.map { try contents($0) }.joined()
        XCTAssertTrue(all.contains("continuing in a fresh file"))
        for i in 0..<20 {
            XCTAssertTrue(all.contains("number \(i)\n"), "line \(i) was lost across a roll")
        }
    }

    func testPruningKeepsOnlyRecentFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("RemSound-old.log")
        let recent = directory.appendingPathComponent("RemSound-recent.log")
        let notALog = directory.appendingPathComponent("notes.txt")
        for url in [old, recent, notALog] {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        let longAgo = Date().addingTimeInterval(-EventLog.keepDays - 3600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

        let log = makeLog()
        log.prune()
        log.flushForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notALog.path), "only .log files are ours")
    }
}
