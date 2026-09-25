import Foundation
import XCTest

@testable import AgentWatchLookup

/// Claude Code's own record of a process knows it as the agent's when its path no longer can:
/// after an update deleted the version it runs, or while the kernel reports it under the second
/// name a background session gave the file. `docs/agent-integration.md` §1б.
final class ClaudeSessionRegistryTests: XCTestCase {
    private var directory: URL!

    /// 2026-09-14 15:06:01 UTC, the start the kernel and the record both gave for the agent
    /// left behind in `mcp-hub`.
    private let started = Date(timeIntervalSince1970: 1_789_398_361)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("agent-watch-session-registry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAProcessIsKnownByItsRecordWhenTheTwoStartsAgree() throws {
        try record(#"{"pid":39806,"kind":"interactive","procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "39806.json")
        let registry = registry(starts: [39806: started])

        XCTAssertTrue(registry.recordsLiveProcess(39806))
        XCTAssertEqual(registry.liveProcessIDs(), [39806])
    }

    /// The record is a file, and a file can outlive its process; the number then comes back
    /// attached to a stranger, who must not become a row.
    func testANumberHandedOutAgainIsNotTheRecordedProcess() throws {
        try record(#"{"pid":39806,"procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "39806.json")
        let registry = registry(starts: [39806: started + 3_600])

        XCTAssertFalse(registry.recordsLiveProcess(39806))
        XCTAssertEqual(registry.liveProcessIDs(), [])
    }

    func testAProcessThatHasGoneIsNotKnown() throws {
        try record(#"{"pid":39806,"procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "39806.json")

        XCTAssertFalse(registry(starts: [:]).recordsLiveProcess(39806))
    }

    /// Without a start there is no telling the recorded process from a stranger under its
    /// number — and here the answer builds a row, so it is refused rather than trusted.
    func testARecordWithoutAStartKnowsNoProcess() throws {
        try record(#"{"pid":39806,"kind":"interactive"}"#, as: "39806.json")

        XCTAssertFalse(registry(starts: [39806: started]).recordsLiveProcess(39806))
    }

    func testARecordAboutAnotherProcessSpeaksForNeither() throws {
        try record(#"{"pid":401,"procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "400.json")
        let registry = registry(starts: [400: started, 401: started])

        XCTAssertFalse(registry.recordsLiveProcess(400))
        XCTAssertFalse(registry.recordsLiveProcess(401))
        XCTAssertEqual(registry.liveProcessIDs(), [])
    }

    /// Beside every record Claude Code keeps a `<pid>.<hash>.key` file, and a folder that is
    /// not there at all is a machine without Claude Code.
    func testOnlyRecordsAreReadAndAMissingFolderKnowsNothing() throws {
        try record(#"{"pid":39806,"procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "39806.db773a6c.key")
        try record(#"{"pid":39806,"procStart":"Mon Sep 14 15:06:01 2026"}"#, as: "notes.json")
        try record("not json", as: "7.json")

        XCTAssertEqual(registry(starts: [39806: started, 7: started]).liveProcessIDs(), [])
        let started = started
        let missing = ClaudeSessionRegistry(
            directory: directory.appendingPathComponent("absent", isDirectory: true),
            startTime: { _ in started }
        )
        XCTAssertEqual(missing.liveProcessIDs(), [])
        XCTAssertFalse(missing.recordsLiveProcess(39806))
    }

    private func registry(starts: [Int32: Date]) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(directory: directory, startTime: { starts[$0] })
    }

    private func record(_ contents: String, as name: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }
}
