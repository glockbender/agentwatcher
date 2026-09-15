import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// Claude Code's own record of one of its processes, `~/.claude/sessions/<pid>.json`, as a
/// source of one fact and one only: the dialog this session was waiting on is gone.
///
/// Why it is needed at all: nothing else observes the moment a person answers. The hooks
/// report the request (`PermissionRequest`) and, much later, the end of the call that was
/// approved; the transcript writes nothing in between. Measured on this machine, a `git push`
/// approved at once left the row claiming "approval needed" for the 89 seconds the command
/// then ran.
final class ClaudeSessionStatusTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000)

    func testTheRecordSayingNoDialogIsUpEndsAWait() throws {
        var engine = SessionStateEngine()
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .sessionStarted, observedAt: start))
        try engine.ingest(
            testEvent(sessionLabel: "alpha", kind: .turnStarted, observedAt: start + 1, mode: .standard))
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .userInputRequired, observedAt: start + 2))

        let updated = engine.apply(
            ClaudeSessionStatus(state: .busy, updatedAt: start + 3),
            toSessionWithID: "claude:alpha"
        )

        XCTAssertEqual(updated?.phase, .executing)
        XCTAssertNil(updated?.userInputRequestKind)
    }

    func testARecordStillShowingADialogLeavesTheWaitAlone() throws {
        var engine = SessionStateEngine()
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .sessionStarted, observedAt: start))
        try engine.ingest(
            testEvent(sessionLabel: "alpha", kind: .turnStarted, observedAt: start + 1, mode: .standard))
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .userInputRequired, observedAt: start + 2))

        let updated = engine.apply(
            ClaudeSessionStatus(state: .waiting, updatedAt: start + 3),
            toSessionWithID: "claude:alpha"
        )

        XCTAssertNil(updated)
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.phase, .waitingForUser)
    }

    /// The ordering that decides the whole rule. `PermissionRequest` reaches this app before
    /// the dialog is on screen — read in Claude Code's own code, where the hook is consumed
    /// as part of the permission decision and the person is asked only afterwards — so at the
    /// moment the wait is raised the record still says `busy` from whenever the turn began.
    /// A rule that read the state alone would clear every wait as it was raised, and no
    /// dialog would ever light a lamp.
    func testAStatusFromBeforeTheDialogOpenedDoesNotEndTheWait() throws {
        var engine = SessionStateEngine()
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .sessionStarted, observedAt: start))
        try engine.ingest(
            testEvent(sessionLabel: "alpha", kind: .turnStarted, observedAt: start + 1, mode: .standard))
        try engine.ingest(testEvent(sessionLabel: "alpha", kind: .userInputRequired, observedAt: start + 2))

        let updated = engine.apply(
            ClaudeSessionStatus(state: .busy, updatedAt: start + 1),
            toSessionWithID: "claude:alpha"
        )

        XCTAssertNil(updated)
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.phase, .waitingForUser)
    }

    /// Codex keeps no such record, so a Codex row can only ever be reached by this through a
    /// mistake — a session label that collides, a caller that forgot to ask the source. The
    /// one door refuses it rather than trusting every caller to remember.
    func testACodexRowIsNeverTouchedByClaudeCodesRecord() throws {
        var engine = SessionStateEngine()
        try engine.ingest(
            testEvent(source: .codex, sessionLabel: "alpha", kind: .sessionStarted, observedAt: start))
        try engine.ingest(
            testEvent(
                source: .codex, sessionLabel: "alpha", kind: .turnStarted, observedAt: start + 1,
                mode: .standard))
        try engine.ingest(
            testEvent(source: .codex, sessionLabel: "alpha", kind: .userInputRequired, observedAt: start + 2))

        let updated = engine.apply(
            ClaudeSessionStatus(state: .busy, updatedAt: start + 3),
            toSessionWithID: "codex:alpha"
        )

        XCTAssertNil(updated)
        XCTAssertEqual(engine.snapshots["codex:alpha"]?.phase, .waitingForUser)
    }

    // MARK: - Reading the record

    /// The record as Claude Code 2.1.272 writes it, fields and all, taken from this machine
    /// while a dialog was up. `statusUpdatedAt` is milliseconds since the epoch.
    func testTheRecordIsReadAsClaudeCodeWritesIt() throws {
        let record = Data(
            """
            {"pid":22983,"sessionId":"464a8e07","cwd":"/somewhere","kind":"interactive",\
            "status":"waiting","waitingFor":"permission prompt",\
            "updatedAt":1789483499020,"statusUpdatedAt":1789483499020}
            """.utf8)

        let status = try XCTUnwrap(ClaudeSessionStatus(sessionRecord: record))

        XCTAssertEqual(status.state, .waiting)
        XCTAssertEqual(status.updatedAt, Date(timeIntervalSince1970: 1_789_483_499.020))
    }
}
