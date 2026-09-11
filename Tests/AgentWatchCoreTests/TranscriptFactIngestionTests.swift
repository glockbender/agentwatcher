import Foundation
import XCTest

@testable import AgentWatchCore

/// The transcript's way into the engine. What matters here is not that a fact reaches the
/// reducer — `SessionReducerTests` covers the rules themselves — but that it arrives under
/// the same two guards a hook event does. A transcript read is late by construction, so it
/// is the most likely source of exactly the out-of-order facts those guards exist for.
final class TranscriptFactIngestionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    func testTheTranscriptClosesACallNoHookEverClosed() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))

        let changed = engine.apply(.callReturned(activityID: "call-1", at: start + 5), toSessionWithID: sessionID)

        XCTAssertEqual(changed?.activities.map(\.id), [])
    }

    /// A background shell is answered at once with a handle while the command runs on, so its
    /// own call returning must not close it. Only the notification of the work ending does.
    func testABackgroundCommandSurvivesItsCallAndEndsOnTheNotification() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1", outlivesItsCall: true))

        let afterReturn = engine.apply(.callReturned(activityID: "call-1", at: start + 5), toSessionWithID: sessionID)
        XCTAssertNil(afterReturn, "the call returning is not the work ending")
        XCTAssertEqual(engine.snapshots[sessionID]?.activities.map(\.id), ["call-1"])

        let afterEnd = engine.apply(.workEnded(activityID: "call-1", at: start + 90), toSessionWithID: sessionID)
        XCTAssertEqual(afterEnd?.activities.map(\.id), [])
    }

    func testAnInterruptedTurnComesToRestRatherThanCompleting() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))

        let interrupted = engine.apply(.turnInterrupted(at: start + 20), toSessionWithID: sessionID)

        XCTAssertEqual(interrupted?.phase, .idle, "nothing completed, so nothing may say completed")
        XCTAssertEqual(interrupted?.activities, [])
    }

    /// A person who stops a turn and immediately types the next one is ahead of this reader:
    /// the marker is still unread when the new turn's hook lands. Applied a poll later, it
    /// would empty a turn that had only just begun and leave the row at rest while the agent
    /// worked.
    func testAnInterruptionOlderThanTheNewestThingHeardIsIgnored() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(turnStarted(at: start + 12))

        let ignored = engine.apply(.turnInterrupted(at: start + 10), toSessionWithID: sessionID)

        XCTAssertNil(ignored)
        XCTAssertEqual(
            engine.snapshots[sessionID]?.phase,
            .executing,
            "the turn running now is not the one that was stopped"
        )
    }

    /// The same guard must not touch the facts it was not written for. A call ending is named
    /// by its identifier, so closing one that is already closed changes nothing whatever the
    /// order — and its record is nearly always older than the last hook heard.
    func testACallEndingIsStillTakenWhenItIsOlderThanTheLastHook() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))
        try engine.ingest(turnStarted(at: start + 60))
        try engine.ingest(callStarted(id: "call-2"))

        let changed = engine.apply(.callReturned(activityID: "call-2", at: start + 30), toSessionWithID: sessionID)

        XCTAssertEqual(changed?.activities.map(\.id), [])
    }

    // MARK: - What a session says about itself

    /// Both numbers come out of one record the agent wrote, which is the whole reason a
    /// percentage is allowed here. The rule kept for Claude — a count read from a transcript
    /// never wears a percentage measured elsewhere — is about two measurements passing for
    /// one, and two halves of a single record are not that.
    func testTheContextPercentageIsComputedFromOneRecordsTwoNumbers() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let described = engine.applySignals(
            TranscriptSignals(contextInputTokens: 124_247, contextWindowTokens: 258_400),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(described?.contextTelemetry?.totalInputTokens, 124_247)
        XCTAssertEqual(described?.contextTelemetry?.usedPercentage ?? 0, 48.08, accuracy: 0.01)
    }

    /// A count with no window is still a count. It is the percentage that needs both.
    func testACountWithNoWindowIsShownWithoutAPercentage() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let described = engine.applySignals(
            TranscriptSignals(contextInputTokens: 26_142),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(described?.contextTelemetry?.totalInputTokens, 26_142)
        XCTAssertNil(described?.contextTelemetry?.usedPercentage)
    }

    /// The count and the window are written at different moments of the same turn, so a
    /// little over is a rounding of the truth. Going quiet exactly as the context fills would
    /// lose the number at the moment it matters most.
    func testAFullContextIsHeldAtAHundredRatherThanPassingIt() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let described = engine.applySignals(
            TranscriptSignals(contextInputTokens: 300_000, contextWindowTokens: 258_400),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(described?.contextTelemetry?.usedPercentage, 100)
    }

    /// One increment carries a turn's model and no counts, the next the other way round.
    /// Neither may blank what the other found.
    func testASignalTheReadingIsSilentAboutKeepsWhatItHad() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        engine.applySignals(
            TranscriptSignals(modelName: "gpt-5.6-terra", gitBranch: "main"),
            toSessionWithID: sessionID
        )

        let later = engine.applySignals(
            TranscriptSignals(contextInputTokens: 26_142),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(later?.modelName, "gpt-5.6-terra")
        XCTAssertEqual(later?.gitBranch, "main")
        XCTAssertEqual(later?.contextTelemetry?.totalInputTokens, 26_142)
        XCTAssertNil(
            engine.applySignals(TranscriptSignals(), toSessionWithID: sessionID),
            "a reading that found nothing is not a change"
        )
    }

    /// Not one field here is a lifecycle fact, which is why this is a separate entry point
    /// rather than another case of `apply`.
    func testSignalsMoveNeitherThePhaseNorTheAge() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let described = engine.applySignals(
            TranscriptSignals(modelName: "claude-opus-5", threadKind: .subagent),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(described?.phase, .executing)
        XCTAssertEqual(described?.lastObservedAt, start)
    }

    func testAClosedSessionTakesNoFurtherDescription() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        engine.markSessionClosed(id: sessionID, at: start + 30)

        XCTAssertNil(engine.applySignals(TranscriptSignals(modelName: "m"), toSessionWithID: sessionID))
    }

    // MARK: - Being heard without saying anything

    /// A turn spent thinking, or writing a long answer, calls nothing and delivers no hook
    /// while its transcript grows the whole time. Without this the silence rule would call
    /// that session silent while the reader was busy reading it.
    func testGrowthWithNoFactInItStillCountsAsHavingHeardTheSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        let unheard = try XCTUnwrap(engine.snapshots[sessionID])
        XCTAssertTrue(
            SessionSilence.isUnexplained(unheard, now: start + SessionSilence.defaultUnexplainedAfter)
        )

        let heard = try XCTUnwrap(engine.markObserved(at: start + 100, forSessionWithID: sessionID))

        XCTAssertEqual(heard.lastObservedAt, start + 100)
        XCTAssertFalse(SessionSilence.isUnexplained(heard, now: start + SessionSilence.defaultUnexplainedAfter))
    }

    func testHearingSomethingOlderThanWhatIsAlreadyKnownChangesNothing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted(at: start + 60))

        XCTAssertNil(engine.markObserved(at: start + 10, forSessionWithID: sessionID))
        XCTAssertEqual(engine.snapshots[sessionID]?.lastObservedAt, start + 60)
    }

    /// A transcript outlives the session that wrote it, and the retention clock counts from
    /// the age. A closed row must not keep getting younger.
    func testAClosedSessionIsNotStirredByItsFileStillGrowing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        engine.markSessionClosed(id: sessionID, at: start + 30)

        XCTAssertNil(engine.markObserved(at: start + 90, forSessionWithID: sessionID))
        XCTAssertEqual(engine.snapshots[sessionID]?.lastObservedAt, start + 30)
    }

    // MARK: - The guards

    /// The transcript keeps every ending forever, so a poll that starts reading a session
    /// which has since been closed would replay its whole life back into a terminal state.
    func testAFactCannotStirAClosedSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))
        engine.markSessionClosed(id: sessionID, at: start + 30)

        XCTAssertNil(engine.apply(.turnInterrupted(at: start + 40), toSessionWithID: sessionID))
        XCTAssertEqual(engine.snapshots[sessionID]?.phase, .sessionClosed)
    }

    /// A transcript record is dated by the transcript, and a poll reads it seconds later —
    /// so the age a row shows must be the age of the newest thing heard, not of whichever
    /// packet arrived last.
    func testALateFactDoesNotAgeTheSessionBackwards() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))
        try engine.ingest(turnStarted(at: start + 60))

        engine.apply(.callReturned(activityID: "call-1", at: start + 5), toSessionWithID: sessionID)

        XCTAssertEqual(engine.snapshots[sessionID]?.lastObservedAt, start + 60)
    }

    /// Nearly every fact is one a hook already delivered. Reporting each of those as a change
    /// would fill the debug log with agreement and hide the disagreements it exists to show.
    func testAFactTheHooksAlreadyDeliveredIsNotReportedAsAChange() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(callStarted(id: "call-1"))
        try engine.ingest(callCompleted(id: "call-1", at: start + 4))

        XCTAssertNil(engine.apply(.callReturned(activityID: "call-1", at: start + 4), toSessionWithID: sessionID))
    }

    /// Reading the file is itself evidence the session is alive. A session whose hooks have
    /// stopped but whose transcript is still being read is being watched, and the silence
    /// rule must not be told otherwise.
    func testAFactThatChangesNothingStillCountsAsHavingHeardSomething() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        engine.apply(.callReturned(activityID: "unknown-call", at: start + 45), toSessionWithID: sessionID)

        XCTAssertEqual(engine.snapshots[sessionID]?.lastObservedAt, start + 45)
    }

    func testAFactForASessionNobodyAnnouncedIsDropped() {
        var engine = SessionStateEngine()

        XCTAssertNil(engine.apply(.turnInterrupted(at: start), toSessionWithID: "claude:nobody"))
        XCTAssertTrue(engine.snapshots.isEmpty)
    }

    // MARK: - Faults

    func testAFaultIsRecordedWithoutTouchingThePhase() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let faulted = engine.setMonitoringFault(.transcriptNotFound, forSessionWithID: sessionID)

        XCTAssertEqual(faulted?.monitoringFault, .transcriptNotFound)
        XCTAssertEqual(faulted?.phase, .executing)
    }

    /// The reader only watches a session that claims to be working, so once the turn ends
    /// nothing is left that could clear the fault. Left standing, a warning raised at 10:00
    /// would sit on a finished row for the rest of its life, saying the session is working
    /// beside a lamp that says it completed.
    func testAFaultDoesNotOutliveTheWorkItWasAbout() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        engine.setMonitoringFault(.unexplainedSilence, forSessionWithID: sessionID)

        try engine.ingest(turnCompleted(at: start + 30))

        XCTAssertEqual(engine.snapshots[sessionID]?.phase, .completed)
        XCTAssertNil(engine.snapshots[sessionID]?.monitoringFault)
    }

    /// The same rule for every other way out of a working phase, because each of them ends
    /// the watching just as completely.
    func testEveryWayOutOfWorkClearsTheFault() throws {
        let waysOutOfWork: [(String, (inout SessionStateEngine, Date) -> Void)] = [
            ("the session closed", { engine, at in engine.markSessionClosed(id: "claude:alpha", at: at) }),
            (
                "the connection was lost",
                { engine, at in
                    engine.markUnwatchedSessionsDisconnected(now: at, after: 1, watchedSessionIDs: [])
                }
            ),
            (
                "a person stopped the turn",
                { engine, at in engine.apply(.turnInterrupted(at: at), toSessionWithID: "claude:alpha") }
            ),
        ]

        for (name, leave) in waysOutOfWork {
            var engine = SessionStateEngine()
            try engine.ingest(turnStarted())
            engine.setMonitoringFault(.transcriptNotFound, forSessionWithID: sessionID)

            leave(&engine, start + 30)

            XCTAssertNil(engine.snapshots[sessionID]?.monitoringFault, "\(name) left a stale warning")
        }
    }

    /// The mirror of the rule in `SessionReducer`. That one drops a fault once the phase
    /// leaves work; this one refuses a fault that was still on its way when it did. The
    /// reader works a poll behind, so a complaint computed while a turn ran can arrive after
    /// it ended — and nothing would ever clear it, because a session at rest is not watched.
    func testAFaultThatArrivesAfterTheWorkEndedIsRefused() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(turnCompleted(at: start + 30))

        XCTAssertNil(engine.setMonitoringFault(.unexplainedSilence, forSessionWithID: sessionID))
        XCTAssertNil(engine.snapshots[sessionID]?.monitoringFault)
    }

    /// Recomputed on every tick, so an unchanged fault has to be silent — otherwise the
    /// widget redraws and the debug log grows once per tick for as long as the fault lasts.
    func testAnUnchangedFaultReportsNothing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        engine.setMonitoringFault(.transcriptNotFound, forSessionWithID: sessionID)

        XCTAssertNil(engine.setMonitoringFault(.transcriptNotFound, forSessionWithID: sessionID))
        XCTAssertNotNil(engine.setMonitoringFault(nil, forSessionWithID: sessionID))
    }

    // MARK: - Helpers

    private let sessionID = "claude:alpha"

    // MARK: - The call only the transcript sees

    /// An advisor call reaches the widget through no other route: it runs on Anthropic's side,
    /// so neither `PreToolUse` nor `PostToolUse` fires. The transcript opens it and closes it.
    func testAnAdvisorCallOpensAndClosesThroughTheTranscriptAlone() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())

        let opened = engine.apply(
            .callStarted(activityID: "advisor-1", kind: .advisor, at: start + 5),
            toSessionWithID: sessionID
        )
        XCTAssertEqual(opened?.activities.map(\.kind), [.advisor])

        let closed = engine.apply(.callReturned(activityID: "advisor-1", at: start + 95), toSessionWithID: sessionID)
        XCTAssertEqual(closed?.activities.map(\.id), [])
    }

    /// The closing record can be missed — a re-synchronised read skips whatever it jumped
    /// over — and an advisor call left open would then claim the session was consulting an
    /// advisor for the rest of its life. The end of the turn is what sweeps it: an advisor
    /// call cannot outlive the turn that issued it.
    func testAnAdvisorCallLeftOpenIsSweptByTheEndOfTheTurn() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        _ = engine.apply(
            .callStarted(activityID: "advisor-1", kind: .advisor, at: start + 5),
            toSessionWithID: sessionID
        )

        let completed = try engine.ingest(turnCompleted(at: start + 30))

        XCTAssertEqual(completed.activities.map(\.id), [])
        XCTAssertEqual(completed.phase, .completed)
    }

    /// One poll reads every working session, and each fact is routed by the session it was
    /// read for. Two agents consulting an advisor at the same moment is ordinary on this
    /// machine, so a fact landing on the wrong row would be a lie about what the other one is
    /// doing.
    func testAnAdvisorCallLandsOnlyOnTheSessionItWasReadFor() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(turnStarted(sessionID: "beta"))

        _ = engine.apply(
            .callStarted(activityID: "advisor-1", kind: .advisor, at: start + 5),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(engine.snapshots[sessionID]?.activities.map(\.kind), [.advisor])
        XCTAssertEqual(engine.snapshots["claude:beta"]?.activities.map(\.kind), [])
    }

    /// The transcript is read seconds late, so an advisor call arrives carrying a timestamp
    /// older than the newest hook. The age must not follow it backwards: a row that jumped
    /// back would read as quieter than the session really is, which is the one thing the
    /// timer beside it exists to say honestly.
    func testAnAdvisorCallReadLateDoesNotAgeTheSessionBackwards() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted())
        try engine.ingest(turnStarted(at: start + 60))

        _ = engine.apply(
            .callStarted(activityID: "advisor-1", kind: .advisor, at: start + 5),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(engine.snapshots[sessionID]?.lastObservedAt, start + 60)
        XCTAssertEqual(
            engine.snapshots[sessionID]?.activities.map(\.kind), [.advisor],
            "the call is still real, only its clock is behind"
        )
    }

    // MARK: - What the file says the session is about

    /// A session renames itself as its work moves on — three titles in one long session,
    /// measured. The remembered copy is whatever it was when the app last ran, so after a
    /// restart the file is the fresher of the two and wins.
    func testATitleReadFromTheFileReplacesTheRememberedOne() throws {
        var engine = SessionStateEngine()
        try engine.ingest(turnStarted(describedAs: SessionDescription(title: "what it used to be about")))

        let described = engine.applyDescription(
            SessionDescription(title: "what it is about now"),
            toSessionWithID: sessionID
        )

        XCTAssertEqual(described?.title, "what it is about now")
    }

    private func turnStarted(
        at observedAt: Date? = nil,
        sessionID: String = "alpha",
        describedAs description: SessionDescription? = nil
    ) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: sessionID,
            description: description,
            observedAt: observedAt ?? start,
            kind: .turnStarted,
            mode: .standard
        )
    }

    private func callStarted(id: String, outlivesItsCall: Bool = false) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: "alpha",
            activityID: id,
            observedAt: start + 1,
            kind: .activityStarted,
            mode: .standard,
            activityKind: .shell,
            activityOutlivesItsCall: outlivesItsCall
        )
    }

    private func turnCompleted(at observedAt: Date) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: "alpha",
            observedAt: observedAt,
            kind: .turnCompleted,
            mode: .standard
        )
    }

    private func callCompleted(id: String, at observedAt: Date) -> EventEnvelope {
        EventEnvelope(
            source: .claude,
            sessionID: "alpha",
            activityID: id,
            observedAt: observedAt,
            kind: .activityCompleted,
            mode: .standard
        )
    }
}
