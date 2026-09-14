import Foundation
import XCTest

@testable import AgentWatchCore

/// `/bg` and `/fork` continue a conversation in a new process under a new session identifier.
/// Measured on Claude Code 2.1.269: the copy starts as `claude --fork-session --resume <the
/// original's transcript>`, sends `SessionStart` under its own identifier, and the original
/// process stays alive but silent. One conversation, and the widget drew two rows for it.
final class SessionForkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    /// The fork's first event lands on the original's row, which becomes the fork's: the
    /// process number and the kind of place it runs in move over, and no second row appears.
    func testAForkContinuesTheRowOfTheSessionItWasCopiedFrom() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))

        let continued = try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"
            )
        )

        XCTAssertEqual(continued.id, "claude:alpha")
        XCTAssertEqual(engine.snapshots.count, 1, "one conversation, one row")
        XCTAssertEqual(continued.agentProcessID, 502)
        XCTAssertEqual(continued.clientKind, .background)
    }

    /// Everything the copy does from then on is the row's: its turns move the row's lamp.
    func testTheForksLaterEventsMoveTheOriginalsRow() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(
            event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, forkedFrom: "alpha"))

        let working = try engine.ingest(event(label: "beta", kind: .turnStarted, at: start + 20))

        XCTAssertEqual(working.id, "claude:alpha")
        XCTAssertEqual(working.phase, .executing)
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A copy of a session this app never saw is a session like any other: there is no row to
    /// continue, so it gets one of its own rather than none.
    func testAForkOfAnUnknownSessionIsARowOfItsOwn() throws {
        var engine = SessionStateEngine()

        let fork = try engine.ingest(
            event(label: "beta", kind: .sessionStarted, at: start, processID: 502, forkedFrom: "nobody"))

        XCTAssertEqual(fork.id, "claude:beta")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// The alias is written to the file with the row, so a restart does not split the
    /// conversation back into two: the copy's next event finds its row through the memory.
    func testTheContinuationSurvivesARestart() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(
            event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, forkedFrom: "alpha"))

        var relaunched = SessionStateEngine()
        relaunched.restore(SessionHistory.records(of: engine.snapshots.values))
        let heardAgain = try relaunched.ingest(event(label: "beta", kind: .turnStarted, at: start + 3_600))

        XCTAssertEqual(heardAgain.id, "claude:alpha")
        XCTAssertEqual(relaunched.snapshots.count, 1)
    }

    /// A copy that already has a row of its own — the file of a launch before this rule
    /// existed holds both — is folded into the original's row: the row a person saw two of
    /// becomes one, and the copy's later events keep landing on it.
    func testAForkThatAlreadyHasARowIsFoldedIntoTheOriginal() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502))

        let late = event(label: "beta", kind: .turnStarted, at: start + 20, processID: 502, forkedFrom: "alpha")
        let folded = engine.foldContinuedRow(for: late)
        let row = try engine.ingest(late)

        XCTAssertEqual(folded?.id, "claude:beta", "the copy's own row is the one that goes")
        XCTAssertEqual(row.id, "claude:alpha")
        XCTAssertEqual(row.phase, .executing)
        XCTAssertEqual(row.agentProcessID, 502)
        XCTAssertEqual(Set(engine.snapshots.keys), ["claude:alpha"])
        XCTAssertEqual(
            try engine.ingest(event(label: "beta", kind: .turnCompleted, at: start + 30)).id,
            "claude:alpha",
            "and from then on the copy's identifier is the original's"
        )
    }

    /// Nothing is folded when there is no original to fold into, and nothing when the event
    /// names no original at all.
    func testNothingIsFoldedWithoutAnOriginalRow() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "beta", kind: .sessionStarted, at: start, processID: 502))

        XCTAssertNil(
            engine.foldContinuedRow(for: event(label: "beta", kind: .turnStarted, at: start + 1, forkedFrom: "nobody")))
        XCTAssertNil(engine.foldContinuedRow(for: event(label: "beta", kind: .turnStarted, at: start + 1)))
        XCTAssertEqual(Set(engine.snapshots.keys), ["claude:beta"])
    }

    /// A closed row is terminal, and only a start reopens it. A copy heard of mid-conversation
    /// whose original has since closed must not disappear into that tombstone: it is a row of
    /// its own until a start of its own says otherwise.
    func testAForkDoesNotContinueAClosedRowExceptByStarting() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(event(label: "alpha", kind: .sessionEnded, at: start + 5, processID: 501))

        let midway = try engine.ingest(
            event(label: "beta", kind: .turnStarted, at: start + 10, processID: 502, forkedFrom: "alpha"))
        XCTAssertEqual(midway.id, "claude:beta", "a turn cannot bring a closed row back, so it gets its own")
        XCTAssertEqual(midway.phase, .executing)

        var again = SessionStateEngine()
        try again.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try again.ingest(event(label: "alpha", kind: .sessionEnded, at: start + 5, processID: 501))
        let reopened = try again.ingest(
            event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, forkedFrom: "alpha"))
        XCTAssertEqual(reopened.id, "claude:alpha", "a start is the one way back into a closed row")
        XCTAssertEqual(reopened.phase, .idle)
    }

    /// The two-second session `--resume` leaves behind on the copy's process is retired as it
    /// always was, and the original — live, and now the copy's row — is not touched.
    func testTheStubAResumeLeavesOnTheForksProcessIsRetiredAndTheOriginalIsNot() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(event(label: "stub", kind: .sessionStarted, at: start + 8, processID: 502))
        try engine.ingest(event(label: "stub", kind: .sessionEnded, at: start + 9, processID: 502))

        let forkStart = event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, forkedFrom: "alpha")
        let retired = engine.retireSessionsSuperseded(by: forkStart)
        try engine.ingest(forkStart)

        XCTAssertEqual(retired.map(\.id), ["claude:stub"])
        XCTAssertEqual(Set(engine.snapshots.keys), ["claude:alpha"])
    }

    /// A closed row whose process has moved on is retired when another session starts there —
    /// the rule for the stub `--resume` leaves behind. A copy's own late event must not turn
    /// that rule against the row it continues: the copy ended the row, and a `Stop` of its own
    /// straggling in after the end arrives under the copy's identifier on the same process.
    func testACopysOwnLateEventDoesNotRetireTheRowItContinues() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501))
        try engine.ingest(
            event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, forkedFrom: "alpha"))
        try engine.ingest(event(label: "beta", kind: .sessionEnded, at: start + 20, processID: 502))

        let straggler = event(label: "beta", kind: .turnCompleted, at: start + 21, processID: 502)
        XCTAssertEqual(engine.retireSessionsSuperseded(by: straggler), [])
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.phase, .sessionClosed, "closed it stays; retired it is not")
    }

    /// After `/bg` the original process lives on, idle, until its terminal is closed — and then
    /// it says `SessionEnd`. The conversation did not end; it moved. An end from a process that
    /// is not the row's current one closes nothing.
    func testTheOriginalProcessEndingDoesNotCloseARowTheCopyRunsNow() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        try engine.ingest(event(label: "beta", kind: .turnStarted, at: start + 20, processID: 502))

        let row = try engine.ingest(event(label: "alpha", kind: .sessionEnded, at: start + 30, processID: 501))

        XCTAssertEqual(row.phase, .executing, "the copy is still working")
        XCTAssertEqual(row.agentProcessID, 502, "and the row stays on the copy's process")
        XCTAssertEqual(row.clientKind, .background)

        let ended = try engine.ingest(event(label: "beta", kind: .sessionEnded, at: start + 40, processID: 502))
        XCTAssertEqual(ended.phase, .sessionClosed, "the copy's own end is the conversation's end")
    }

    /// `/fork` is the other way a copy comes about, and there the original keeps working. Two
    /// live sessions are two rows, whatever the copy's arguments say: the moment the original
    /// takes a turn or a call of its own after the copy joined, the copy is let go — its next
    /// event is a row of its own, and the original's row is the original's again.
    func testAnOriginalThatKeepsWorkingLetsTheCopyGo() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(event(label: "alpha", kind: .turnStarted, at: start + 1, processID: 501))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))

        let original = try engine.ingest(
            event(label: "alpha", kind: .activityStarted, at: start + 12, processID: 501, clientKind: .cli))
        XCTAssertEqual(original.id, "claude:alpha")
        XCTAssertEqual(original.agentProcessID, 501)
        XCTAssertNil(original.continuedBy, "the copy is no longer a name for this row")

        let copy = try engine.ingest(event(label: "beta", kind: .turnStarted, at: start + 15, processID: 502))
        XCTAssertEqual(copy.id, "claude:beta", "a row of its own from here on")
        XCTAssertEqual(Set(engine.snapshots.keys), ["claude:alpha", "claude:beta"])
    }

    /// The original's trailing words are not signs of life. After `/bg` the turn the original
    /// was in the middle of ends in the copy, and the original may still report its own end of
    /// turn; that is not a turn of its own, and it does not let the copy go.
    func testTheOriginalsTrailingEndOfTurnDoesNotLetTheCopyGo() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(event(label: "alpha", kind: .turnStarted, at: start + 1, processID: 501))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))

        let row = try engine.ingest(event(label: "alpha", kind: .turnCompleted, at: start + 11, processID: 501))

        XCTAssertEqual(row.continuedBy, ["beta"], "still one conversation")
        XCTAssertEqual(try engine.ingest(event(label: "beta", kind: .turnStarted, at: start + 15)).id, "claude:alpha")
    }

    /// And the trailing words change nothing else either. The sender puts the process and
    /// the kind of place it runs in on every hook, so the original's trailing end of turn
    /// says "process 501, a terminal" — and taking that at its word would move the row's
    /// life to a process that is only idling, drop the terminal showing the copy, and end a
    /// turn the copy is in the middle of. Until the original takes a turn of its own, the
    /// row is the copy's, whatever the original's process says.
    func testTheOriginalsTrailingEndOfTurnChangesNothingOnTheRow() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(event(label: "alpha", kind: .turnStarted, at: start + 1, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        engine.setViewer(processID: 501, forSessionWithID: "claude:alpha")
        let working = try engine.ingest(
            event(label: "beta", kind: .turnStarted, at: start + 11, processID: 502, clientKind: .background))

        let row = try engine.ingest(
            event(label: "alpha", kind: .turnCompleted, at: start + 12, processID: 501, clientKind: .cli))

        XCTAssertEqual(row.agentProcessID, 502, "the copy is still what the row lives and dies with")
        XCTAssertEqual(row.clientKind, .background)
        XCTAssertEqual(row.viewerProcessID, 501, "the terminal still shows it")
        XCTAssertEqual(row.phase, working.phase, "the copy's turn is not ended by the original's")
        XCTAssertEqual(row.continuedBy, ["beta"])
    }

    /// Every hook of the copy names the original — the sender reads it from the copy's own
    /// arguments — so the name alone cannot be what joins a copy to a row: a copy that was let
    /// go would join again on its next hook, and the row would merge and split on every turn.
    /// Let go is remembered on the original's row, and the file keeps it with the row, so a
    /// restart does not fold the two back into one either.
    func testALetGoCopyStaysARowOfItsOwnWhateverItsHooksName() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        try engine.ingest(event(label: "alpha", kind: .turnStarted, at: start + 12, processID: 501, clientKind: .cli))

        let copy = try engine.ingest(
            event(
                label: "beta", kind: .turnStarted, at: start + 15, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))

        XCTAssertEqual(copy.id, "claude:beta", "a row of its own, although its hook names the original")
        let original = try XCTUnwrap(engine.snapshots["claude:alpha"])
        XCTAssertNil(original.continuedBy)
        XCTAssertEqual(original.agentProcessID, 501)

        var relaunched = SessionStateEngine()
        relaunched.restore(SessionHistory.records(of: engine.snapshots.values))
        let later = event(
            label: "beta", kind: .turnStarted, at: start + 3_600, processID: 502, clientKind: .background,
            forkedFrom: "alpha")
        XCTAssertNil(relaunched.foldContinuedRow(for: later), "not folded back after a restart")
        XCTAssertEqual(try relaunched.ingest(later).id, "claude:beta")
        XCTAssertEqual(relaunched.snapshots.count, 2)
    }

    /// A copy can be copied in turn — `/fork` inside a copy while the original never speaks
    /// again — and then three sessions name one row, in the order they joined. The rule for
    /// the original holds at every link of that chain: a copy that takes a turn of its own
    /// beside copies that joined after it lets those go, and keeps the row for itself and for
    /// the copies before it. A let-go copy's hooks name a session still on the row, and that
    /// joins it no more than naming the original would.
    func testACopyThatKeepsWorkingLetsTheCopiesAfterItGo() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        try engine.ingest(
            event(
                label: "gamma", kind: .sessionStarted, at: start + 20, processID: 503, clientKind: .background,
                forkedFrom: "beta"))
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.continuedBy, ["beta", "gamma"], "one row for the three")

        let middle = try engine.ingest(
            event(
                label: "beta", kind: .turnStarted, at: start + 30, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))

        XCTAssertEqual(middle.id, "claude:alpha")
        XCTAssertEqual(middle.agentProcessID, 502, "the row is the speaking copy's again")
        XCTAssertEqual(middle.continuedBy, ["beta"])
        XCTAssertEqual(middle.releasedCopies, ["gamma"])
        XCTAssertEqual(engine.lastIngestNote, .released(copies: ["gamma"], rowWasClosed: false))
        let latest = try engine.ingest(
            event(
                label: "gamma", kind: .turnStarted, at: start + 40, processID: 503, clientKind: .background,
                forkedFrom: "beta"))
        XCTAssertEqual(latest.id, "claude:gamma", "a row of its own, although its hook names a session on the row")
        XCTAssertEqual(Set(engine.snapshots.keys), ["claude:alpha", "claude:gamma"])
    }

    /// The end that closes the row is the newest copy's, whatever process the row was last
    /// heard on: a copy folded in from the old file ends before any other event of its own
    /// arrives, and the row is still on the original's process then. The conversation ended
    /// all the same.
    func testTheNewestCopysEndClosesTheRowEvenBeforeTheRowHeardItsProcess() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502))

        let end = event(label: "beta", kind: .sessionEnded, at: start + 20, processID: 502, forkedFrom: "alpha")
        engine.foldContinuedRow(for: end)
        let row = try engine.ingest(end)

        XCTAssertEqual(row.id, "claude:alpha")
        XCTAssertEqual(row.phase, .sessionClosed, "the copy's own end is the conversation's end")
    }

    /// The newest copy's end closes the row, and the original may well be alive behind it:
    /// after `/fork` the copy is often finished first, and the person then keeps typing in
    /// the original. Its turn is proof of life, and closed is not where a live session stays:
    /// the row reopens for it, the way a start would reopen it.
    func testTheOriginalSpeakingAgainReopensARowTheCopysEndClosed() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        let closed = try engine.ingest(event(label: "beta", kind: .sessionEnded, at: start + 20, processID: 502))
        XCTAssertEqual(closed.phase, .sessionClosed)

        let alive = try engine.ingest(
            event(label: "alpha", kind: .turnStarted, at: start + 30, processID: 501, clientKind: .cli))

        XCTAssertEqual(alive.id, "claude:alpha")
        XCTAssertEqual(alive.phase, .executing, "a live session working, not a tombstone")
        XCTAssertEqual(alive.agentProcessID, 501)
        XCTAssertEqual(alive.clientKind, .cli)
        XCTAssertNil(alive.continuedBy)
        XCTAssertEqual(alive.releasedCopies, ["beta"])
        XCTAssertEqual(engine.lastIngestNote, .released(copies: ["beta"], rowWasClosed: true))
    }

    /// `claude --resume <the original's id>` in a fresh terminal is the original coming back,
    /// and its turn is what says so. Its `SessionStart` is not: a start under the row's own
    /// identifier is also what the parked terminal may say when a person walks back into the
    /// session from the agent list — not measured — and reading that as a second live session
    /// would split one conversation into two rows, the very thing this rule prevents. So the
    /// start changes nothing and the first turn lets the copy go, one event later.
    func testTheOriginalsOwnStartIsNotWhatLetsTheCopyGo() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))

        let started = try engine.ingest(
            event(label: "alpha", kind: .sessionStarted, at: start + 20, processID: 601, clientKind: .cli))

        XCTAssertEqual(started.agentProcessID, 502, "the row is still the copy's")
        XCTAssertEqual(started.continuedBy, ["beta"])
        XCTAssertNil(started.releasedCopies)
        XCTAssertNil(engine.lastIngestNote)

        let turn = try engine.ingest(
            event(label: "alpha", kind: .turnStarted, at: start + 30, processID: 601, clientKind: .cli))

        XCTAssertEqual(turn.id, "claude:alpha")
        XCTAssertEqual(turn.agentProcessID, 601)
        XCTAssertNil(turn.continuedBy)
        XCTAssertEqual(turn.releasedCopies, ["beta"])
        XCTAssertEqual(engine.lastIngestNote, .released(copies: ["beta"], rowWasClosed: false))
    }

    /// Which session spoke is read from the event's label and the row's chain, not from the
    /// process number: an original's word that arrives without one — the sender could not
    /// find its process — is still the original's, and still not the row's while a copy holds
    /// it. Its end closes nothing; its end of turn ends nothing.
    func testTheOriginalsWordsWithoutAProcessNumberChangeNothingEither() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        let working = try engine.ingest(event(label: "beta", kind: .turnStarted, at: start + 11, processID: 502))

        let afterStop = try engine.ingest(event(label: "alpha", kind: .turnCompleted, at: start + 12))
        let afterEnd = try engine.ingest(event(label: "alpha", kind: .sessionEnded, at: start + 13))

        XCTAssertEqual(afterStop.phase, working.phase)
        XCTAssertEqual(afterEnd.phase, working.phase, "the copy is still working")
        XCTAssertEqual(afterEnd.continuedBy, ["beta"])
    }

    // MARK: - The terminal that shows the copy

    /// `/bg` leaves the terminal it was typed in showing the session: the interactive process
    /// stays alive and attached to the job. The row runs on the copy — that is what closes it
    /// and what its hooks name — but a person finds the session in that terminal, so a click
    /// and the icon belong to the terminal while it is there.
    func testATerminalShowingTheCopyIsWhereTheRowIsReached() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        let unseen = try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        XCTAssertEqual(unseen.hostKind, .background, "with no terminal showing it, the row is a background one")
        XCTAssertEqual(unseen.hostProcessID, 502)

        let shown = try XCTUnwrap(engine.setViewer(processID: 501, forSessionWithID: "claude:alpha"))

        XCTAssertEqual(shown.viewerProcessID, 501)
        XCTAssertEqual(shown.clientKind, .background, "what the process is has not changed")
        XCTAssertEqual(shown.hostKind, .cli, "where a person finds it has")
        XCTAssertEqual(shown.hostProcessID, 501, "the click walks up from the terminal, not from the copy")
        XCTAssertEqual(shown.agentProcessID, 502, "the copy is still what the row lives and dies with")
    }

    /// The terminal closing takes the viewer away, and the row is a background one again: the
    /// session runs on, and a click now has to open it.
    func testTheViewerLeavingMakesTheRowABackgroundOneAgain() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        engine.setViewer(processID: 501, forSessionWithID: "claude:alpha")

        let alone = try XCTUnwrap(engine.setViewer(processID: nil, forSessionWithID: "claude:alpha"))

        XCTAssertNil(alone.viewerProcessID)
        XCTAssertEqual(alone.hostKind, .background)
        XCTAssertEqual(alone.hostProcessID, 502)
    }

    /// A viewer belongs to a background row only. When the row's session speaks from a terminal
    /// of its own again — the original working on beside its `/fork` copy — the terminal *is*
    /// the row's process, and a viewer left over from before would point the click at it twice.
    func testAnEventFromATerminalProcessDropsTheViewer() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        engine.setViewer(processID: 501, forSessionWithID: "claude:alpha")

        let working = try engine.ingest(
            event(label: "alpha", kind: .turnStarted, at: start + 20, processID: 501, clientKind: .cli))

        XCTAssertNil(working.viewerProcessID)
        XCTAssertEqual(working.hostKind, .cli)
        XCTAssertEqual(working.hostProcessID, 501)
    }

    /// Written to the file with the row, like the alias: a restart must not turn the terminal
    /// back into a door. And a file from before the field existed still reads.
    func testTheViewerIsRememberedWithTheRow() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        let shown = try XCTUnwrap(engine.setViewer(processID: 501, forSessionWithID: "claude:alpha"))

        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(shown))
        XCTAssertEqual(restored.viewerProcessID, 501)

        var withoutField = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shown)) as? [String: Any]
        withoutField?["viewerProcessID"] = nil
        let older = try JSONDecoder().decode(
            SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: withoutField as Any))
        XCTAssertNil(older.viewerProcessID)
    }

    /// The terminal showing the copy is a live `claude` process with no hooks of its own — the
    /// original's process, silent since `/bg`. The scan must not build a row for it: it is the
    /// window of a row that already exists, not an agent nobody has heard from.
    func testTheScanDoesNotBuildARowForTheTerminalShowingTheCopy() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        engine.setViewer(processID: 501, forSessionWithID: "claude:alpha")

        let change = engine.reconcileDiscoveredProcesses([
            DiscoveredAgentProcess(source: .claude, processID: 501, startedAt: start, projectName: "agent-watch")
        ])

        XCTAssertTrue(change.added.isEmpty, "\(change.added.map(\.id))")
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A viewer shows one job. When a further copy joins the row — `/fork` in the terminal
    /// showing the copy — the row is a new job's, and the terminal that parked the old one is
    /// not known to show it. The viewer is dropped, so the application asks again.
    func testAFurtherCopyJoiningDropsTheViewerOfTheCopyBefore() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(
                label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background,
                forkedFrom: "alpha"))
        engine.setViewer(processID: 501, forSessionWithID: "claude:alpha")

        let further = try engine.ingest(
            event(
                label: "gamma", kind: .sessionStarted, at: start + 20, processID: 503, clientKind: .background,
                forkedFrom: "beta"))

        XCTAssertEqual(further.id, "claude:alpha")
        XCTAssertNil(further.viewerProcessID, "the terminal parked the copy's job, not this one")
        XCTAssertEqual(further.hostKind, .background)
    }

    /// What the copy's own row knew moves over with it when it folds into the original's: the
    /// terminal showing it, and the copies it had let go — which must not join the original's
    /// row through the copy's name once the copy's own row is gone.
    func testAFoldCarriesTheCopysOwnViewerAndLetGoCopiesOver() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(label: "alpha", kind: .sessionStarted, at: start, processID: 501, clientKind: .cli))
        try engine.ingest(
            event(label: "beta", kind: .sessionStarted, at: start + 10, processID: 502, clientKind: .background))
        try engine.ingest(
            event(
                label: "gamma", kind: .sessionStarted, at: start + 20, processID: 503, clientKind: .background,
                forkedFrom: "beta"))
        try engine.ingest(
            event(label: "beta", kind: .turnStarted, at: start + 30, processID: 502, clientKind: .background))
        engine.setViewer(processID: 601, forSessionWithID: "claude:beta")
        XCTAssertEqual(engine.snapshots["claude:beta"]?.releasedCopies, ["gamma"])

        let late = event(
            label: "beta", kind: .turnCompleted, at: start + 40, processID: 502, clientKind: .background,
            forkedFrom: "alpha")
        engine.foldContinuedRow(for: late)
        let row = try engine.ingest(late)

        XCTAssertEqual(row.id, "claude:alpha")
        XCTAssertEqual(row.viewerProcessID, 601, "the terminal showing the copy shows the row")
        XCTAssertEqual(row.releasedCopies, ["gamma"])
        let letGo = try engine.ingest(
            event(
                label: "gamma", kind: .turnStarted, at: start + 50, processID: 503, clientKind: .background,
                forkedFrom: "beta"))
        XCTAssertEqual(letGo.id, "claude:gamma", "let go it stays")
    }

    private func event(
        label: String,
        kind: EventKind,
        at observedAt: Date,
        processID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        forkedFrom: String? = nil
    ) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: label,
            observedAt: observedAt,
            kind: kind,
            mode: .standard,
            agentProcessID: processID,
            clientKind: clientKind,
            forkedFromSessionID: forkedFrom
        )
    }
}
