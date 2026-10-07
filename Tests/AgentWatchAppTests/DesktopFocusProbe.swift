import AgentWatchCore
import AgentWatchLookup
import AppKit
import XCTest

@testable import AgentWatchApp

/// A click on a desktop client's session, made against the real Claude.app and ChatGPT.app on
/// this machine. Run it after either application updates, to re-check the two link rows of
/// `docs/measurements.md`:
///
///     DESKTOP_FOCUS_PROBE_CLAUDE_PID=<pid> swift test --filter DesktopFocusProbe
///     DESKTOP_FOCUS_PROBE_CODEX_THREAD=<thread id> swift test --filter DesktopFocusProbe
///
/// The process is one Claude.app runs for a session — `entrypoint: "claude-desktop"` in
/// `~/.claude/sessions/<pid>.json` — and the thread is one in `~/.codex/session_index.jsonl`.
/// Each brings its application forward and switches it to that session, which is the point:
/// pass the session already on screen to see nothing move. Whether the application followed is
/// in its own log, not here — `setFocusedSession` in `~/Library/Logs/Claude/main.log`,
/// `thread_stream_view_activity_changed` in ChatGPT's. Your own Agent Watch can stay open.
@MainActor
final class DesktopFocusProbe: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func testAClickOnAClaudeAppSessionAsksClaudeAppForIt() throws {
        let named = ProcessInfo.processInfo.environment["DESKTOP_FOCUS_PROBE_CLAUDE_PID"]
        try XCTSkipUnless(named != nil, "switches Claude.app to another session")
        let processID = try XCTUnwrap(named.flatMap { Int32($0) }, "not a process number")
        let record = try XCTUnwrap(
            ClaudeSessionRegistry().record(ofLiveProcess: processID), "no live record for process \(processID)")
        let sessionID = try XCTUnwrap(record.sessionID)
        let snapshot = SessionSnapshot(
            id: SessionSnapshot.id(
                source: .claude, sessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionID)),
            source: .claude,
            arrivalIndex: 0,
            lastObservedAt: Date(),
            agentProcessID: processID,
            clientKind: .desktop
        )

        let outcome = SessionHostRegistry(onAgentProcessExit: { _ in }).focus(snapshot)

        XCTAssertTrue(outcome.raised)
        XCTAssertEqual(outcome.tab, .asked)
    }

    func testAClickOnAChatGPTThreadAsksChatGPTForIt() throws {
        let named = ProcessInfo.processInfo.environment["DESKTOP_FOCUS_PROBE_CODEX_THREAD"]
        try XCTSkipUnless(named != nil, "switches ChatGPT.app to another thread")
        let thread = try XCTUnwrap(named)
        let label = HookCaptureRedactor.label(forRawIdentifier: thread)
        let snapshot = SessionSnapshot(
            id: SessionSnapshot.id(source: .codex, sessionLabel: label),
            source: .codex,
            arrivalIndex: 0,
            lastObservedAt: Date(),
            clientKind: .desktop
        )
        let root = TranscriptLocator.defaultRoot(for: .codex, home: home)
        let registry = SessionHostRegistry(
            onAgentProcessExit: { _ in },
            transcriptOfSession: { snapshot in
                TranscriptLocator.locate(sessionLabel: snapshot.transcriptLabel, source: .codex, root: root)
                    ?? TranscriptLocator.locate(
                        sessionLabel: snapshot.transcriptLabel, source: .codex,
                        root: TranscriptLocator.codexArchivedSessions(inRoot: root))
            }
        )

        let outcome = registry.focus(snapshot)

        XCTAssertTrue(outcome.raised)
        XCTAssertEqual(outcome.tab, .asked)
    }
}
