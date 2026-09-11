import Foundation
import XCTest

@testable import AgentWatchApp

/// The log is written on every accepted event, so what it costs per event matters more than
/// what it costs once.
@MainActor
final class EventDebugLogTests: XCTestCase {
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
