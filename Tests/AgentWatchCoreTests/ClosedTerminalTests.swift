import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// A session whose terminal was closed while its agent stayed behind.
///
/// Measured on Claude Code 2.1.270 and 2.1.280 in a JetBrains terminal tab: the agent does
/// not exit, it hangs on its way out, and nothing can reach it any more. The row has to say
/// so — before this it said `idle`, or `no signal` after a restart, and a click raised the
/// IDE, which had no tab left to show.
final class ClosedTerminalTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    func testATerminalSessionWhoseTerminalWasClosedWaitsForAPerson() throws {
        var engine = SessionStateEngine()
        try engine.ingest(terminalEvent(.sessionStarted, at: started))
        let waiting = try engine.ingest(terminalEvent(.userInputRequired, at: started + 5))
        XCTAssertTrue(waiting.isAwaitingAnswer)

        let row = try XCTUnwrap(engine.markTerminalClosed(forSessionWithID: waiting.id))

        XCTAssertEqual(row.phase, .terminalClosed)
        XCTAssertEqual(row.phase.attention, .needsPerson, "only a person can end what is left")
        // The dialog was on the screen that went away; nobody can answer it now.
        XCTAssertFalse(row.isAwaitingAnswer)
        // The mark is the app's own finding, not something the session did: the row's age
        // keeps saying how long the session has been silent.
        XCTAssertEqual(row.lastObservedAt, started + 5)
        XCTAssertEqual(engine.snapshots[waiting.id], row)
    }

    /// Whatever the row said was running went with the terminal: the agent is hung on its way
    /// out, and a card still listing a subagent and a background task would be saying the
    /// opposite of the lamp beside it. The same clearing a closed session gets, through the
    /// same function every way out of a working phase takes.
    func testNothingIsLeftRunningOnceTheTerminalIsGone() {
        var row = testSession(
            phase: .executing,
            activities: [SessionActivity(id: "call-1", kind: .shell, startedAt: started)],
            clientKind: .cli,
            lastObservedAt: started + 5
        )
        row.backgroundWork = [.shell]
        row.monitoringFault = .unexplainedSilence

        let marked = SessionReducer.reduce(row, event: .terminalClosed)

        XCTAssertEqual(marked.phase, .terminalClosed)
        XCTAssertEqual(marked.activities, [])
        XCTAssertNil(marked.backgroundWork)
        XCTAssertNil(marked.monitoringFault, "nothing claims work, so nothing can be missed")
        XCTAssertEqual(marked.lastObservedAt, started + 5)
    }

    func testMarkingARowAgainChangesNothing() throws {
        var engine = SessionStateEngine()
        let row = try engine.ingest(terminalEvent(.sessionStarted, at: started))
        XCTAssertNotNil(engine.markTerminalClosed(forSessionWithID: row.id))

        XCTAssertNil(engine.markTerminalClosed(forSessionWithID: row.id))
    }

    /// A background session runs in the agent's own pty and a desktop one in an application:
    /// neither was ever in a terminal a person could close.
    func testOnlyATerminalSessionCanLoseItsTerminal() throws {
        var engine = SessionStateEngine()
        // Its start takes no row — a background session gets one on its first turn.
        _ = try engine.receive(
            testEvent(sessionLabel: "background", observedAt: started, agentProcessID: 7, clientKind: .background))
        let background = try engine.ingest(
            testEvent(
                sessionLabel: "background", kind: .turnStarted, observedAt: started + 1, agentProcessID: 7,
                clientKind: .background))
        let desktop = try engine.ingest(
            testEvent(source: .codex, sessionLabel: "desktop", observedAt: started, clientKind: .desktop))

        XCTAssertNil(engine.markTerminalClosed(forSessionWithID: background.id))
        XCTAssertNil(engine.markTerminalClosed(forSessionWithID: desktop.id))
    }

    func testASessionThatEndedIsLeftAlone() throws {
        var engine = SessionStateEngine()
        try engine.ingest(terminalEvent(.sessionStarted, at: started))
        let closed = try engine.ingest(terminalEvent(.sessionEnded, at: started + 1))

        XCTAssertNil(engine.markTerminalClosed(forSessionWithID: closed.id))
        XCTAssertEqual(engine.snapshots[closed.id]?.phase, .sessionClosed)
    }

    /// The row built from a process is the case that was reported: the app restarted and
    /// found the agent still running, with nothing ever heard from it.
    func testARowBuiltFromAProcessKeepsTheMarkThroughTheNextScan() throws {
        var engine = SessionStateEngine()
        let process = DiscoveredAgentProcess(source: .claude, processID: 5_929, startedAt: started, projectName: "devx")
        let row = try XCTUnwrap(engine.reconcileDiscoveredProcesses([process]).added.first)
        XCTAssertNotNil(engine.markTerminalClosed(forSessionWithID: row.id))

        XCTAssertTrue(engine.reconcileDiscoveredProcesses([process]).isEmpty)
        XCTAssertEqual(engine.snapshots[row.id]?.phase, .terminalClosed)
    }

    /// Nothing is left to wait for: the agent will not speak again, so the `×` is there at once.
    func testTheRowCanBeDismissedAtOnce() {
        let row = testSession(phase: .terminalClosed, lastObservedAt: started)

        XCTAssertEqual(SessionPresence.dismissal(of: row, now: started), .now)
    }

    // MARK: - Rows a person took away

    /// The case reported on the owner's machine: a row dismissed by hand, and its agent's
    /// last hook arriving afterwards. It brings no closed row back, and says why.
    func testTheEndOfADismissedRowMakesNoRowAgain() throws {
        var engine = SessionStateEngine()
        let row = try engine.ingest(terminalEvent(.sessionStarted, at: started))
        engine.dismissSession(id: row.id)

        let change = try engine.receive(terminalEvent(.sessionEnded, at: started + 5))

        XCTAssertNil(change.row)
        XCTAssertEqual(change.withheld, .endedAfterItsRowWasDismissed)
        XCTAssertNil(engine.snapshots[row.id])
        XCTAssertTrue(engine.wasDismissed(row.id))
    }

    /// Only a person's dismissal counts: a row taken away for any other reason — a process row
    /// whose agent ended — does not silence the session's end.
    func testARowRemovedForAnotherReasonIsNotADismissal() throws {
        var engine = SessionStateEngine()
        let row = try engine.ingest(terminalEvent(.sessionStarted, at: started))
        engine.removeSession(id: row.id)

        let change = try engine.receive(terminalEvent(.sessionEnded, at: started + 5))

        XCTAssertNil(change.withheld)
        XCTAssertFalse(engine.wasDismissed(row.id))
    }

    /// Asked to end its agent, a row goes when its session closes — not at the answer, and not
    /// while it is still without its terminal.
    func testARowAskedToEndGoesWhenItsSessionCloses() throws {
        var engine = SessionStateEngine()
        let row = try engine.ingest(terminalEvent(.sessionStarted, at: started))
        _ = try XCTUnwrap(engine.markTerminalClosed(forSessionWithID: row.id))
        engine.removeWhenClosed(id: row.id)

        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [], "the agent has not ended yet")
        XCTAssertNotNil(engine.snapshots[row.id])

        try engine.ingest(terminalEvent(.sessionEnded, at: started + 5))
        let taken = engine.takeRowsEndedAsAsked()

        XCTAssertEqual(taken.map(\.id), [row.id])
        XCTAssertNil(engine.snapshots[row.id])
        XCTAssertTrue(engine.wasDismissed(row.id), "and its end arriving again makes no row")
        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [])
    }

    /// A row back at work is no longer the one a person asked about: when it closes much
    /// later, it closes like any other.
    func testARowBackAtWorkIsNoLongerTakenAway() throws {
        var engine = SessionStateEngine()
        let row = try engine.ingest(terminalEvent(.sessionStarted, at: started))
        _ = try XCTUnwrap(engine.markTerminalClosed(forSessionWithID: row.id))
        engine.removeWhenClosed(id: row.id)

        try engine.ingest(terminalEvent(.turnStarted, at: started + 5))
        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [])
        try engine.ingest(terminalEvent(.sessionEnded, at: started + 60))

        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [])
        XCTAssertEqual(engine.snapshots[row.id]?.phase, .sessionClosed)
    }

    private func terminalEvent(_ kind: EventKind, at observedAt: Date) -> EventEnvelope {
        testEvent(sessionLabel: "devx", kind: kind, observedAt: observedAt, agentProcessID: 5_929, clientKind: .cli)
    }
}
