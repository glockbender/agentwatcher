import AppKit
import Foundation
import XCTest

@testable import AgentWatchApp

/// The log is written on every accepted event, so what it costs per event matters more than
/// what it costs once.
@MainActor
final class EventDebugLogTests: XCTestCase {
    /// Environment overrides are process-wide, so this probe runs in its own xctest rather
    /// than changing the environment of tests executing in parallel.
    func testDefaultLogHonorsTheDebugSupportOverride() throws {
        let environment = ProcessInfo.processInfo.environment
        if let expectedDirectory = environment["AGENT_WATCH_LOG_TEST_DIRECTORY"] {
            let log = EventDebugLog()
            log.append("isolated log probe")
            let output = URL(fileURLWithPath: expectedDirectory)
                .appendingPathComponent("AgentWatch/event-debug.log")
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "isolated log probe\n")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LogOverride-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest", "-XCTest", "AgentWatchAppTests.EventDebugLogTests/testDefaultLogHonorsTheDebugSupportOverride",
            Bundle(for: Self.self).bundlePath,
        ]
        var childEnvironment = environment
        childEnvironment["AGENT_WATCH_LOG_TEST_DIRECTORY"] = directory.path
        childEnvironment["AGENT_WATCH_SUPPORT_DIR"] = directory.path
        child.environment = childEnvironment
        try child.run()
        child.waitUntilExit()

        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("AgentWatch/event-debug.log"), encoding: .utf8),
            "isolated log probe\n"
        )
    }

    func testTheLogStaysBoundedWithoutRewritingItselfOnEveryEntry() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchLogTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let cap = EventDebugLog.maximumEntryCount
        let written = cap * 3
        let log = EventDebugLog(directoryURL: directoryURL)
        for index in 0..<written {
            log.append("entry \(index)")
        }

        XCTAssertEqual(log.recentEntries().count, cap)
        XCTAssertEqual(log.recentEntries().last, "entry \(written - 1)")
        // Twice the cap is the point at which it trims. Anything at the cap would mean it is
        // rewriting the whole file for each entry again.
        XCTAssertLessThanOrEqual(log.storedLineCount, cap * 2)
        XCTAssertGreaterThan(log.storedLineCount, cap)
    }

    /// A restart reads the file back, and the window shows the last `maximumEntryCount` lines of it
    /// however many the file was allowed to keep.
    func testAReopenedLogShowsTheLastEntriesOfTheFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchLogTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let cap = EventDebugLog.maximumEntryCount
        let written = cap + cap / 4
        let first = EventDebugLog(directoryURL: directoryURL)
        for index in 0..<written {
            first.append("entry \(index)")
        }

        let reopened = EventDebugLog(directoryURL: directoryURL)

        XCTAssertEqual(reopened.recentEntries().count, cap)
        XCTAssertEqual(reopened.recentEntries().last, "entry \(written - 1)")
    }
    func testLongUnicodeAndMultilineEntriesStaySmallAndSingleLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventDebugLog(directoryURL: directory)
        log.append(String(repeating: "🙂\n", count: 10_000))
        let entry = try XCTUnwrap(log.recentEntries().last)
        XCTAssertLessThanOrEqual(entry.utf8.count, 1024)
        XCTAssertFalse(entry.contains("\n"))
        XCTAssertFalse(entry.contains("�"))
        XCTAssertTrue(entry.hasSuffix("…"))
    }

    func testOversizedExistingFileIsCompactedOnOpenAndExternalGrowthCannotBypassTheLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("event-debug.log")
        let oversized = Data((String(repeating: "old entry\n", count: 150_000) + "newest\n").utf8)
        try oversized.write(to: file)
        let log = EventDebugLog(directoryURL: directory)
        XCTAssertEqual(log.recentEntries().last, "newest")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_048_576)
        try oversized.write(to: file)
        log.append("after external growth")
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1_048_576)
        XCTAssertEqual(log.recentEntries().last, "after external growth")
    }

    func testRepeatedHugeEntriesNeverExceedTheDiskBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = EventDebugLog(directoryURL: directory)
        for _ in 0..<1100 { log.append(String(repeating: "x", count: 4096)) }
        XCTAssertLessThanOrEqual(
            try Data(contentsOf: directory.appendingPathComponent("event-debug.log")).count, 1_048_576)
    }

    func testHiddenDebugWindowKeepsOnlyRecentBoundedEntries() throws {
        let controller = EventDebugWindowController(initialEntries: [])
        for index in 0..<1500 {
            controller.append("entry \(index) " + String(repeating: "x", count: 2048))
        }
        let scroll = try XCTUnwrap(controller.window?.contentView as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView).string
        XCTAssertEqual(text.split(separator: "\n").count, 500)
        XCTAssertTrue(text.hasPrefix("entry 1000 "))
        XCTAssertLessThanOrEqual(text.utf8.count, 500 * 1025)
    }

    /// Entries that arrive while the window is hidden do not scroll it, so opening it has to:
    /// otherwise it opens at the top, and the lines a person opened it for are out of sight.
    func testOpeningTheDebugWindowShowsTheNewestEntry() throws {
        let controller = EventDebugWindowController(initialEntries: [])
        defer { controller.window?.orderOut(nil) }
        for index in 0..<200 {
            controller.append("entry \(index)")
        }

        controller.toggle()

        let scroll = try XCTUnwrap(controller.window?.contentView as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView as? NSTextView)
        // Laid out here rather than left to the scroll: measured, a text view nobody scrolled
        // is still its initial 300 pt, and the check below would pass or fail on that instead.
        let container = try XCTUnwrap(document.textContainer)
        document.layoutManager?.ensureLayout(for: container)
        let clip = scroll.contentView
        XCTAssertGreaterThan(document.frame.height, clip.bounds.height * 2, "the log is not long enough to scroll")
        XCTAssertEqual(clip.bounds.maxY, document.frame.maxY, accuracy: 1, "the window did not open at its end")
    }

    func testFailedCompactionDoesNotAllowTheFileToKeepGrowing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("event-debug.log")
        let log = EventDebugLog(directoryURL: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<1000 { log.append("entry") }
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try Data().write(to: directory.appendingPathComponent("blocked")))
        for _ in 0..<600 { log.append("must not bypass failed compaction") }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// A rewrite that failed is not tried again on the very next event, which is what a full
    /// or read-only disk used to cost: the whole log joined and written for every entry. It is
    /// tried again after as many entries as a working log takes between two rewrites.
    func testAFailedRewriteWaitsBeforeItIsTriedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("event-debug.log")
        let log = EventDebugLog(directoryURL: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<1000 { log.append("entry") }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        log.append("refused")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let afterFailure = try Data(contentsOf: file)

        for _ in 0..<EventDebugLog.maximumEntryCount { log.append("while waiting") }
        XCTAssertEqual(try Data(contentsOf: file), afterFailure, "tried again before its turn")

        log.append("newest")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.last, "newest", "the disk works again, so the log should reach it")
        XCTAssertLessThanOrEqual(lines.count, EventDebugLog.maximumEntryCount + 1)
    }

}
