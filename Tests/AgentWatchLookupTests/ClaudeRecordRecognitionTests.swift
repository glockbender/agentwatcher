import Foundation
import XCTest

@testable import AgentWatchLookup

/// The path to the program knows a Claude process only while the kernel names it the way it
/// was installed. Two measured cases where it does not, both now answered by the process's own
/// record — `docs/agent-integration.md` §1б, «Путь к программе называет файл, а не запуск».
final class ClaudeRecordRecognitionTests: XCTestCase {
    private var directory: URL!
    private let started = Date(timeIntervalSince1970: 1_789_398_361)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("agent-watch-record-recognition-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// An update deletes the version a long-running session was started from, and the kernel
    /// names no path for it any more. Measured on the agent left in `mcp-hub` since
    /// 2026-09-14, on 2.1.270: invisible to the scan, and its hooks would have carried no
    /// process number.
    func testAnAgentWhoseVersionWasDeletedIsKnownByItsRecord() throws {
        let ancestors = [
            ProcessSnapshot(processID: 900, executableName: "sh", executablePath: "/bin/sh"),
            ProcessSnapshot(processID: 39806, executableName: "2.1.270"),
            ProcessSnapshot(processID: 39534, executableName: "zsh", executablePath: "/bin/zsh"),
        ]
        let rules = try rules(recording: [39806])

        XCTAssertEqual(rules.agentProcessID(among: ancestors), 39806)
        XCTAssertEqual(rules.clientKind(among: ancestors, argumentsOfProcess: { _ in ["claude"] }), .cli)
        XCTAssertNil(ClaudeProcessRules.byPathAlone.agentProcessID(among: ancestors))
    }

    /// A background session gives the running version a second name inside `ClaudeCode.app`,
    /// and the kernel reports that name for every process running the file. Measured on the
    /// ordinary `claude --resume` in `mcp-hub` on 2.1.272, 2026-09-15.
    func testAnAgentReportedUnderTheBundlesNameIsKnownByItsRecord() throws {
        let ancestors = [
            ProcessSnapshot(
                processID: 11860,
                executableName: "claude",
                executablePath: "/private/opaque/claude/ClaudeCode.app/Contents/MacOS/claude"
            )
        ]

        XCTAssertEqual(try rules(recording: [11860]).agentProcessID(among: ancestors), 11860)
        XCTAssertNil(ClaudeProcessRules.byPathAlone.agentProcessID(among: ancestors))
    }

    /// Not every session gets a record (a short-lived one raised from a pty did not, on
    /// 2.1.272), so the record adds to the path and replaces nothing.
    func testThePathStillKnowsASessionWithoutARecord() throws {
        let ancestors = [
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.282",
                executablePath: "/private/opaque/claude/versions/2.1.282"
            )
        ]

        XCTAssertEqual(try rules(recording: []).agentProcessID(among: ancestors), 400)
    }

    /// A record says a process is Claude's, not that it is a session: whether the agent's own
    /// helpers write records is not measured, and the helper rule is what decides.
    func testAProcessKnownByItsRecordIsStillAskedWhetherItIsAHelper() throws {
        let ancestors = [
            ProcessSnapshot(processID: 16222, executableName: "2.1.269"),
            ProcessSnapshot(
                processID: 16043,
                executableName: "claude",
                executablePath: "/private/opaque/claude/ClaudeCode.app/Contents/MacOS/claude"
            ),
        ]
        let arguments: [Int32: [String]] = [
            16222: ["/private/opaque/claude/versions/2.1.269", "--session-id", "b95a16c1-0000"],
            16043: ["claude bg-pty-host", "--bg-pty-host", "/private/opaque/pty/b95a16c1.sock"],
        ]

        XCTAssertEqual(
            try rules(recording: [16222, 16043]).clientKind(among: ancestors, argumentsOfProcess: { arguments[$0] }),
            .background
        )
    }

    /// The walk up from a hook used to stop at the first process the kernel names no path for,
    /// and the agent itself is such a process once its version is deleted. It goes on now, and
    /// stops only where there is no process at all.
    func testTheWalkGoesOnPastAProcessTheKernelNamesNoPathFor() {
        let snapshots: [Int32: ProcessSnapshot] = [
            900: ProcessSnapshot(processID: 900, executableName: "sh", executablePath: "/bin/sh"),
            39806: ProcessSnapshot(processID: 39806, executableName: "2.1.270"),
            39534: ProcessSnapshot(processID: 39534, executableName: "zsh", executablePath: "/bin/zsh"),
        ]
        let parents: [Int32: Int32] = [900: 39806, 39806: 39534, 39534: 4837]

        let walked = AgentProcessLocator.ancestorSnapshots(
            startingAt: 900,
            snapshotOf: { snapshots[$0] },
            parentOf: { parents[$0] }
        )

        XCTAssertEqual(walked.map(\.processID), [900, 39806, 39534], "4837 is not running")
    }

    /// A process the kernel names no path for is still a process, known by the name it runs
    /// under; one the kernel knows nothing about is none.
    func testAProcessWithoutAPathIsKnownByItsCommandName() throws {
        let pathless = try XCTUnwrap(
            AgentProcessLocator.snapshot(processID: 39806, executablePath: nil, commandName: "2.1.270"))

        XCTAssertEqual(pathless.executableName, "2.1.270")
        XCTAssertNil(pathless.executablePath)
        XCTAssertNil(AgentProcessLocator.snapshot(processID: 39806, executablePath: nil, commandName: nil))
        XCTAssertEqual(
            AgentProcessLocator.snapshot(processID: 400, executablePath: "/bin/zsh", commandName: "zsh")?
                .executableName,
            "zsh"
        )
        XCTAssertNotNil(AgentProcessLocator.commandName(of: getpid()))
    }

    private func rules(recording processIDs: [Int32]) throws -> ClaudeProcessRules {
        for processID in processIDs {
            try Data(#"{"pid":\#(processID),"procStart":"Mon Sep 14 15:06:01 2026"}"#.utf8)
                .write(to: directory.appendingPathComponent("\(processID).json"))
        }
        let started = started
        let recorded = Set(processIDs)
        return ClaudeProcessRules(
            registry: ClaudeSessionRegistry(
                directory: directory,
                startTime: { recorded.contains($0) ? started : nil }
            ))
    }
}
