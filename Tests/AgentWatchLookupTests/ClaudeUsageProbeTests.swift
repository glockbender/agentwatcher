import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

/// Each test starts a small shell script in Claude Code's place: what a real run costs is the
/// reason the app starts one so rarely.
final class ClaudeUsageProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsTheReplyAndTheRunEndsOnceItsInputIsClosed() throws {
        let stub = try script(
            """
            read line
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
            echo '{"type":"system","subtype":"init"}'
            echo "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"$id\\",\\"response\\":{\\"rate_limits_available\\":true,\\"rate_limits\\":{\\"five_hour\\":{\\"utilization\\":21,\\"resets_at\\":null}}}}}"
            cat > /dev/null
            """)
        let arrived = Date(timeIntervalSince1970: 1_800_000_000)
        let started = Date()

        let reply = ClaudeUsageProbe.ask(executable: stub, home: root, workingDirectory: root, timeout: 5) { arrived }

        XCTAssertEqual(
            reply,
            .limits(AgentUsageLimits(source: .claude, fiveHour: UsageWindow(usedPercentage: 21), observedAt: arrived)))
        // `cat` returns only when the input is closed, so a quick return proves it was.
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testARefusalComesBackAsOne() throws {
        let stub = try script(
            """
            read line
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
            echo "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"error\\",\\"request_id\\":\\"$id\\",\\"error\\":\\"Unsupported\\"}}"
            """)
        XCTAssertEqual(ClaudeUsageProbe.ask(executable: stub, home: root, workingDirectory: root, timeout: 5), .refused)
    }

    /// A run that never answers is ended at the deadline, not waited for.
    func testARunThatNeverAnswersIsEndedAtTheDeadline() throws {
        let stub = try script("exec sleep 30")
        let started = Date()

        XCTAssertNil(ClaudeUsageProbe.ask(executable: stub, home: root, workingDirectory: root, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    /// A run that dies before reading must not take the app down with it (SIGPIPE).
    func testARunThatExitsAtOnceIsNoAnswer() throws {
        let stub = try script("exit 3")
        XCTAssertNil(ClaudeUsageProbe.ask(executable: stub, home: root, workingDirectory: root, timeout: 2))
    }

    func testAMissingExecutableIsNoAnswer() {
        XCTAssertNil(
            ClaudeUsageProbe.ask(
                executable: root.appendingPathComponent("absent").path, home: root, workingDirectory: root, timeout: 1))
    }

    /// The run gets the words that keep the person's tools, MCP servers, settings and hooks
    /// out of it, and an environment with nothing beyond what finds Claude Code's own files.
    func testRunsWithTheIsolatingWordsAndAMinimalEnvironment() throws {
        let record = root.appendingPathComponent("record")
        let stub = try script(
            """
            for word in "$@"; do printf '[%s]\\n' "$word"; done > "\(record.path).args"
            env | cut -d= -f1 | sort > "\(record.path).env"
            """)

        _ = ClaudeUsageProbe.ask(executable: stub, home: root, workingDirectory: root, timeout: 2)

        let words = try String(contentsOf: URL(fileURLWithPath: record.path + ".args"), encoding: .utf8)
        XCTAssertEqual(words, ClaudeUsageProbe.arguments.map { "[\($0)]\n" }.joined())
        let names = try String(contentsOf: URL(fileURLWithPath: record.path + ".env"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let allowed: Set<String> = ["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]
        XCTAssertTrue(Set(names).isSubset(of: allowed), "unexpected variables: \(Set(names).subtracting(allowed))")
        XCTAssertTrue(names.contains("HOME"))
    }

    /// The run is a Claude Code at the usual path, and the app's own scan of processes would
    /// otherwise make a headless row of it.
    func testAClaudeTheAppStartedIsNotASession() {
        let parents: [Int32: Int32] = [700: 42, 701: 1]
        XCTAssertTrue(ClaudeProcessRules.isStartedByThisProcess(700, parentOf: { parents[$0] }, ownProcessID: 42))
        XCTAssertFalse(ClaudeProcessRules.isStartedByThisProcess(701, parentOf: { parents[$0] }, ownProcessID: 42))
        XCTAssertFalse(ClaudeProcessRules.isStartedByThisProcess(702, parentOf: { parents[$0] }, ownProcessID: 42))
    }

    private func script(_ body: String) throws -> String {
        let file = root.appendingPathComponent("claude-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }
}
