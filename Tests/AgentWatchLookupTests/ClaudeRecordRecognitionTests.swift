import Foundation
import XCTest

@testable import AgentWatchLookup

/// The path to the program knows a Claude process only while the kernel names it the way it
/// was installed. Two measured cases where it does not, both now answered by the process's own
/// record — `docs/agent-processes.md`, «Путь к программе называет файл, а не запуск».
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

    /// Not every session gets a record (a short-lived one raised from a pty did not,
    /// measured on Claude Code 2.1.272), so the record adds to the path and replaces nothing.
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

    /// Claude.app runs each of its sessions as a process of its own, under its `disclaimer`
    /// helper, from a path the path rule does not know — and says so in the process's record.
    /// Measured on Claude.app 2.26454.0 with Claude Code 2.1.289, on all four such processes.
    func testASessionClaudeAppStartedIsADesktopOne() throws {
        let ancestors = [
            ProcessSnapshot(processID: 900, executableName: "sh", executablePath: "/bin/sh"),
            ProcessSnapshot(
                processID: 8864,
                executableName: "claude",
                executablePath:
                    "/Users/someone/Library/Application Support/Claude/claude-code/2.1.289/ee67e3f1ea60/claude.app/Contents/MacOS/claude"
            ),
            ProcessSnapshot(
                processID: 8863, executableName: "disclaimer",
                executablePath: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            ProcessSnapshot(
                processID: 81418, executableName: "Claude",
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
        let rules = try rules(
            recording: [8864],
            fields: #""entrypoint":"claude-desktop","hostSessionId":"local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8""#)

        XCTAssertEqual(rules.agentProcessID(among: ancestors), 8864)
        XCTAssertEqual(rules.clientKind(among: ancestors, argumentsOfProcess: { _ in nil }), .desktop)
        // Its options are those of a run driven by a program — stream-json in and out, a
        // permission tool — but no `-p`, which is what keeps it from reading as one. Measured on
        // Claude Code 2.1.289: read whole from the three sessions open in Claude.app, here with
        // the tool list and the settings shortened.
        let appSession = [
            "/Users/someone/Library/Application Support/Claude/claude-code/2.1.289/ee67e3f1ea60/claude.app/Contents/MacOS/claude",
            "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--model", "claude-opus-5-5", "--permission-prompt-tool", "stdio",
            "--resume=1e4ffa7d-7801-4cae-aea3-a9b0c2b8b614", "--allowedTools", "mcp__computer-use",
            "--disallowedTools", "SubscribePR", "--setting-sources=user,project,local",
            "--permission-mode", "auto", "--allow-dangerously-skip-permissions", "--include-partial-messages",
            "--await-initialize", "--thinking-display", "omitted", "--replay-user-messages",
            "--settings", #"{"deniedMcpServers":[]}"#,
        ]
        XCTAssertEqual(rules.clientKind(among: ancestors, argumentsOfProcess: { _ in appSession }), .desktop)
    }

    /// `claude` typed into Claude.app's own terminal pane runs under the app as well, but in a
    /// terminal — one it can lose like any other — and its record says it was typed.
    func testClaudeTypedIntoATerminalUnderClaudeAppIsNoDesktopSession() throws {
        let ancestors = [
            ProcessSnapshot(
                processID: 400, executableName: "2.1.289", executablePath: "/private/opaque/claude/versions/2.1.289"),
            ProcessSnapshot(processID: 300, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(
                processID: 81418, executableName: "Claude",
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]

        XCTAssertEqual(
            try rules(recording: [400], fields: #""entrypoint":"cli""#)
                .clientKind(among: ancestors, argumentsOfProcess: { _ in nil }),
            .cli
        )
        XCTAssertEqual(
            ClaudeProcessRules.byPathAlone.clientKind(among: ancestors, argumentsOfProcess: { _ in nil }),
            .cli
        )
    }

    /// `claude -p` run by a Claude.app session's shell tool inherits the app's
    /// `CLAUDE_CODE_ENTRYPOINT`: its record says `claude-desktop` with no `hostSessionId`, as
    /// measured on Claude Code 2.1.293. Its own `-p` is what says it is a run.
    func testClaudeMinusPRunFromAClaudeAppSessionIsHeadless() throws {
        let ancestors = [
            ProcessSnapshot(processID: 900, executableName: "sh", executablePath: "/bin/sh"),
            ProcessSnapshot(
                processID: 400, executableName: "2.1.293", executablePath: "/private/opaque/claude/versions/2.1.293"),
            ProcessSnapshot(processID: 300, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(
                processID: 8864, executableName: "claude",
                executablePath:
                    "/Users/someone/Library/Application Support/Claude/claude-code/2.1.289/ee67e3f1ea60/claude.app/Contents/MacOS/claude"
            ),
        ]
        let rules = try rules(recording: [400, 8864], fields: #""entrypoint":"claude-desktop""#)
        let arguments: [Int32: [String]] = [
            400: ["/Users/someone/.local/bin/claude", "-p", "--model", "haiku", "Reply with the single word: ok"]
        ]

        XCTAssertEqual(rules.clientKind(among: ancestors, argumentsOfProcess: { arguments[$0] }), .headless)
    }

    /// The same run with no `-p` in sight, as the Agent SDK starts one: its record is what
    /// is left. `sdk-cli` is what `claude -p` wrote with nothing inherited, on Claude Code
    /// 2.1.293.
    func testARunIsHeadlessByItsRecordWhenItsArgumentsDoNotSay() throws {
        let ancestors = [
            ProcessSnapshot(
                processID: 400, executableName: "2.1.293", executablePath: "/private/opaque/claude/versions/2.1.293")
        ]

        for entrypoint in ["sdk-cli", "sdk-ts", "sdk-py"] {
            XCTAssertEqual(
                try rules(recording: [400], fields: #""entrypoint":"\#(entrypoint)""#)
                    .clientKind(among: ancestors, argumentsOfProcess: { _ in nil }),
                .headless,
                entrypoint
            )
        }
    }

    /// A run started by a background session's shell tool has the pty host above it, which
    /// would make it background, and a click would open `claude attach` for a job it is not.
    func testClaudeMinusPUnderABackgroundSessionIsHeadless() throws {
        let ancestors = [
            ProcessSnapshot(
                processID: 400, executableName: "2.1.293", executablePath: "/private/opaque/claude/versions/2.1.293"),
            ProcessSnapshot(processID: 350, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(
                processID: 300, executableName: "2.1.293", executablePath: "/private/opaque/claude/versions/2.1.293"),
            ProcessSnapshot(
                processID: 200, executableName: "claude",
                executablePath: "/Applications/ClaudeCode.app/Contents/MacOS/claude"),
        ]
        let arguments: [Int32: [String]] = [
            400: ["claude", "--print", "summarise the diff"],
            300: ["/private/opaque/claude/versions/2.1.293", "--fork-session", "--resume", "a.jsonl"],
            200: ["/Applications/ClaudeCode.app/Contents/MacOS/claude", "--bg-pty-host", "3345bfdf"],
        ]

        XCTAssertEqual(
            ClaudeProcessRules.byPathAlone.clientKind(among: ancestors, argumentsOfProcess: { arguments[$0] }),
            .headless
        )
        XCTAssertEqual(
            ClaudeProcessRules.byPathAlone.clientKind(
                among: Array(ancestors.dropFirst(2)), argumentsOfProcess: { arguments[$0] }),
            .background,
            "the session that started it stays background"
        )
    }

    /// The flag and nothing that merely looks like it: a prompt is one argument, and after
    /// `--` every word is the prompt's.
    func testOnlyThePrintFlagMakesARun() {
        XCTAssertTrue(ClaudeProcessRules.isHeadlessRun(["claude", "-p", "hi"]))
        XCTAssertTrue(ClaudeProcessRules.isHeadlessRun(["claude", "--model", "haiku", "--print", "hi"]))
        XCTAssertFalse(ClaudeProcessRules.isHeadlessRun(["claude", "explain -p"]))
        XCTAssertFalse(ClaudeProcessRules.isHeadlessRun(["claude", "--", "-p"]))
        XCTAssertFalse(ClaudeProcessRules.isHeadlessRun(["claude", "--permission-prompt-tool", "stdio"]))
        XCTAssertFalse(ClaudeProcessRules.isHeadlessRun(["claude"]))
    }

    private func rules(recording processIDs: [Int32], fields: String? = nil) throws -> ClaudeProcessRules {
        let extra = fields.map { "," + $0 } ?? ""
        for processID in processIDs {
            try Data(#"{"pid":\#(processID),"procStart":"Mon Sep 14 15:06:01 2026"\#(extra)}"#.utf8)
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
