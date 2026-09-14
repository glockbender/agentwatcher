import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// A background session that has done nothing is not a conversation yet.
///
/// Measured on Claude Code 2.1.270: the agents view always holds one live background
/// session and refills it from a pre-warmed process the instant the current one settles.
/// `~/.claude/daemon.log` shows `bg settled … (done)` and, eight milliseconds later,
/// `bg claimed-spare <new id> (spare)`. Each of those spares sends `SessionStart` and,
/// seconds later, `SessionEnd` — real sessions, and rows nobody asked for: a person who
/// stops one background job watched three empty rows arrive in fifteen seconds.
///
/// A session that takes a turn is a conversation whatever started it, so the rule waits for
/// one rather than trying to tell a spare from a job by its process — measured, both run
/// under `claude bg-spare`, and neither writes a registry record until it is named.
///
/// A terminal session is deliberately not covered: it is a window a person just opened, and
/// `SessionLifecycleTests` holds the rule that its row appears at once.
final class BackgroundSessionRowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 5_000)

    func testABackgroundSessionGetsNoRowUntilItTakesATurn() throws {
        var engine = SessionStateEngine()

        let row = try deliver(
            testEvent(sessionLabel: "spare", observedAt: start, clientKind: .background), to: &engine)

        XCTAssertNil(row, "a start alone says nothing worth a row")
        XCTAssertTrue(engine.snapshots.isEmpty)
    }

    func testABackgroundSessionThatEndsWithoutATurnLeavesNoRow() throws {
        var engine = SessionStateEngine()
        try deliver(testEvent(sessionLabel: "spare", observedAt: start, clientKind: .background), to: &engine)

        try deliver(
            testEvent(sessionLabel: "spare", kind: .sessionEnded, observedAt: start + 6, clientKind: .background),
            to: &engine)

        XCTAssertTrue(engine.snapshots.isEmpty, "no row, and so no tombstone of one either")
    }

    func testABackgroundSessionGetsItsRowOnTheFirstTurn() throws {
        var engine = SessionStateEngine()
        try deliver(testEvent(sessionLabel: "job", observedAt: start, clientKind: .background), to: &engine)

        let row = try XCTUnwrap(
            try deliver(
                testEvent(sessionLabel: "job", kind: .turnStarted, observedAt: start + 1, clientKind: .background),
                to: &engine))

        XCTAssertEqual(row.id, "claude:job")
        XCTAssertEqual(row.phase, .executing)
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// Any sign of life, not only a turn. An app started midway through a background job
    /// hears whatever that job does next — a tool call of its own, or a question for a
    /// person — and a rule that waited for a turn would leave it invisible until the next one.
    func testABackgroundSessionGetsItsRowOnAnyFirstSignOfLife() throws {
        var engine = SessionStateEngine()
        try deliver(testEvent(sessionLabel: "job", observedAt: start, clientKind: .background), to: &engine)

        let row = try XCTUnwrap(
            try deliver(
                testEvent(sessionLabel: "job", kind: .activityStarted, observedAt: start + 1, clientKind: .background),
                to: &engine))

        XCTAssertEqual(row.id, "claude:job")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A session cleared and started again under the same label is alive, and the second
    /// start is its own first sign of life rather than another start to hold back.
    func testASecondStartOnAWithheldLabelGivesItARow() throws {
        var engine = SessionStateEngine()
        try deliver(testEvent(sessionLabel: "job", observedAt: start, clientKind: .background), to: &engine)

        let row = try XCTUnwrap(
            try deliver(
                testEvent(sessionLabel: "job", observedAt: start + 2, clientKind: .background), to: &engine))

        XCTAssertEqual(row.id, "claude:job")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// The copy `/bg` starts continues the row of the session it was copied from. It is that
    /// conversation, on the widget since long before, and holding its start back would take
    /// the row away from a person in the middle of using it.
    func testACopyContinuingARowIsNeverWithheld() throws {
        var engine = SessionStateEngine()
        try deliver(testEvent(sessionLabel: "alpha", observedAt: start, clientKind: .cli), to: &engine)

        let copyStarts = forkStart(label: "beta", forkedFrom: "alpha", at: start + 10)
        let change = try engine.receive(copyStarts)

        XCTAssertNil(change.withheld)
        XCTAssertEqual(change.row?.id, "claude:alpha")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A background job the file remembers is a row already. Its next start — the supervisor
    /// restarts a job on `claude attach` — belongs to that row and is not held back.
    func testARestoredBackgroundSessionIsNeverWithheld() throws {
        var engine = SessionStateEngine()
        engine.restore([
            testSession(index: 3, clientKind: .background, lastObservedAt: start)
        ])
        let restored = try XCTUnwrap(engine.snapshots.values.first)

        let row = try deliver(
            testEvent(sessionLabel: restored.sessionLabel, observedAt: start + 60, clientKind: .background),
            to: &engine)

        XCTAssertEqual(row?.id, restored.id, "the start belongs to the row the file brought back")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// The one door, the same one the application uses.
    @discardableResult
    private func deliver(_ event: EventEnvelope, to engine: inout SessionStateEngine) throws -> SessionSnapshot? {
        try engine.receive(event).row
    }

    private func forkStart(label: String, forkedFrom: String, at observedAt: Date) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: label,
            observedAt: observedAt,
            kind: .sessionStarted,
            mode: .standard,
            agentProcessID: 502,
            clientKind: .background,
            forkedFromSessionID: forkedFrom
        )
    }
}
