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
}
