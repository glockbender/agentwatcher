import Foundation
import XCTest

@testable import AgentWatchCore

/// The one phase a restart may bring back, and the evidence it has to bring back with it.
///
/// A session waiting for a person is the state that does not decay — nothing but that person
/// can end it, and no hook announces it a second time — so it is both the most useful state
/// to restore and the most expensive one to get wrong: the row it produces is the widget's
/// attention state.
final class RememberedWaitTests: XCTestCase {
    private let waitedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// The seam: the file keeps the wait, the engine refuses to claim it. Two rules that used
    /// to be one function, and a row that came back saying "waiting for you" on a memory
    /// alone would be the alarm that is always wrong.
    func testTheFileKeepsTheWaitAndTheEngineStillWillNotClaimIt() throws {
        let waiting = self.waiting()

        let kept = SessionHistory.remembered(waiting)
        XCTAssertEqual(kept.phase, .waitingForUser)
        XCTAssertEqual(kept.awaitedActivityID, "call-1")
        XCTAssertEqual(kept.userInputRequestKind, .approval)

        var engine = SessionStateEngine()
        let restored = try XCTUnwrap(engine.restore([kept]).first)

        XCTAssertEqual(restored.phase, .disconnected, "nothing has been heard, so nothing is claimed yet")
        XCTAssertNil(restored.userInputRequestKind)
        XCTAssertEqual(
            engine.rememberedWaitsAwaitingEvidence["claude:abc"]?.awaitedActivityID,
            "call-1",
            "the wait is set aside, not thrown away"
        )
    }

    /// The transcript agrees: the awaited call never reported back, and nothing at all has
    /// happened since. That is the case this feature exists for.
    func testAWaitTheTranscriptDoesNotContradictComesBack() throws {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        let restored = engine.confirmRememberedWait(
            forSessionWithID: "claude:abc",
            evidence: SessionHistory.RememberedWaitEvidence(awaitedCallEnded: false, newestFactAt: nil)
        )

        XCTAssertEqual(restored?.phase, .waitingForUser)
        XCTAssertEqual(restored?.awaitedActivityID, "call-1")
        XCTAssertEqual(restored?.userInputRequestKind, .approval)
        XCTAssertEqual(restored?.lastObservedAt, waitedAt, "the wait began then, and reading a file is not an event")
        XCTAssertTrue(engine.rememberedWaitsAwaitingEvidence.isEmpty)
    }

    /// The person answered while the app was down: the call reported back, so the wait is
    /// over and the row must not be put back into it.
    ///
    /// Dated at the wait itself rather than after it, which is what makes this the awaited
    /// call's own doing. A record the reader cannot date lands exactly here — so this is the
    /// case where "did anything happen since" says nothing and the identifier decides alone.
    func testAnAnsweredWaitDoesNotComeBack() {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        let restored = engine.confirmRememberedWait(
            forSessionWithID: "claude:abc",
            evidence: SessionHistory.RememberedWaitEvidence(
                facts: [.callReturned(activityID: "call-1", at: waitedAt)],
                awaitedActivityID: "call-1"
            )
        )

        XCTAssertNil(restored)
        XCTAssertEqual(engine.snapshots["claude:abc"]?.phase, .disconnected)
    }

    /// The tail is a window. A session that ran on for a week leaves the awaited call's
    /// result far behind it, so "no result in the tail" cannot carry the answer alone — any
    /// fact newer than the wait says the session moved on without the app.
    func testASessionThatDidAnythingAfterTheWaitIsNotWaiting() {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        let restored = engine.confirmRememberedWait(
            forSessionWithID: "claude:abc",
            evidence: SessionHistory.RememberedWaitEvidence(
                facts: [.callStarted(activityID: "call-9", kind: .shell, at: waitedAt + 3_600)],
                awaitedActivityID: "call-1"
            )
        )

        XCTAssertNil(restored, "a call that started an hour after the wait is a session that was not waiting")
    }

    /// A transcript that could not be found or read says nothing, and nothing is not weak
    /// evidence for a claim about a person.
    func testAWaitNoFileCanAnswerForIsDropped() {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        let restored = engine.confirmRememberedWait(forSessionWithID: "claude:abc", evidence: nil)

        XCTAssertNil(restored)
        XCTAssertEqual(engine.snapshots["claude:abc"]?.phase, .disconnected)
        XCTAssertTrue(engine.rememberedWaitsAwaitingEvidence.isEmpty, "answered either way, so nothing is left over")
    }

    /// An event is the live truth and is younger than any file the app is part-way through
    /// reading. The memory has to lose, and it has to lose without leaving anything behind.
    func testAHookArrivingFirstWinsAndTakesTheMemoryWithIt() throws {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        try engine.ingest(
            EventEnvelope(source: .claude, sessionID: "abc", observedAt: waitedAt + 600, kind: .turnStarted)
        )
        let refused = engine.confirmRememberedWait(
            forSessionWithID: "claude:abc",
            evidence: SessionHistory.RememberedWaitEvidence(awaitedCallEnded: false, newestFactAt: nil)
        )

        XCTAssertNil(refused)
        XCTAssertEqual(engine.snapshots["claude:abc"]?.phase, .executing)
        XCTAssertTrue(engine.rememberedWaitsAwaitingEvidence.isEmpty)
    }

    /// A permission request names no call of its own, and when nothing was open there is
    /// nothing for it to inherit. Such a wait is judged by whether the session did anything
    /// at all afterwards, which is enough on its own.
    func testAWaitNamingNoCallIsStillJudgedByWhatFollowedIt() {
        let wait = SessionHistory.RememberedWait(awaitedActivityID: nil, kind: .approval, observedAt: waitedAt)

        XCTAssertTrue(
            SessionHistory.waitStillHolds(
                wait,
                evidence: SessionHistory.RememberedWaitEvidence(facts: [], awaitedActivityID: nil)
            )
        )
        XCTAssertFalse(
            SessionHistory.waitStillHolds(
                wait,
                evidence: SessionHistory.RememberedWaitEvidence(
                    facts: [.callReturned(activityID: "anything", at: waitedAt + 1)],
                    awaitedActivityID: nil
                )
            )
        )
    }

    /// Every other phase is still left behind, for the reason it always was: a phase claiming
    /// work with no activities and an old age is what `SessionSilence` reports as a fault.
    func testNoOtherPhaseIsKept() {
        for phase in SessionPhase.allCases where phase != .waitingForUser {
            var snapshot = waiting()
            snapshot.phase = phase
            XCTAssertEqual(SessionHistory.remembered(snapshot).phase, .disconnected, "\(phase)")
            XCTAssertNil(SessionHistory.remembered(snapshot).awaitedActivityID, "\(phase)")
        }
    }

    /// The window between restoring and the transcript answering, in which the file is
    /// rewritten anyway.
    ///
    /// `restore` demotes the row to `no signal` and holds the wait in memory alone, and the
    /// application publishes right there — a session leaving is written at once, so the write
    /// is not deferred. If the records took the demoted row at face value, the launch that
    /// exists to bring the wait back would be the thing that erased it, and quitting before
    /// the read finished would lose it for good.
    func testAWaitStillBeingCheckedIsNotErasedFromTheFileByTheLaunchThatRestoredIt() throws {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])

        let written = SessionHistory.records(
            of: engine.snapshots.values,
            awaiting: engine.rememberedWaitsAwaitingEvidence
        )

        let record = try XCTUnwrap(written.first)
        XCTAssertEqual(record.phase, .waitingForUser, "the file goes on saying what it said")
        XCTAssertEqual(record.awaitedActivityID, "call-1")
        XCTAssertEqual(record.userInputRequestKind, .approval)
    }

    /// And once the question is settled the file follows the answer, rather than holding the
    /// wait open for the life of the process.
    func testOnceTheWaitIsAnsweredTheFileFollowsTheAnswer() throws {
        var engine = SessionStateEngine()
        engine.restore([SessionHistory.remembered(waiting())])
        engine.confirmRememberedWait(
            forSessionWithID: "claude:abc",
            evidence: SessionHistory.RememberedWaitEvidence(awaitedCallEnded: true, newestFactAt: nil)
        )

        let written = SessionHistory.records(
            of: engine.snapshots.values,
            awaiting: engine.rememberedWaitsAwaitingEvidence
        )

        XCTAssertEqual(try XCTUnwrap(written.first).phase, .disconnected)
        XCTAssertNil(try XCTUnwrap(written.first).awaitedActivityID)
    }

    private func waiting() -> SessionSnapshot {
        SessionSnapshot(
            id: "claude:abc",
            source: .claude,
            arrivalIndex: 0,
            phase: .waitingForUser,
            userInputRequestKind: .approval,
            awaitedActivityID: "call-1",
            activities: [SessionActivity(id: "call-1", kind: .shell, startedAt: waitedAt - 5)],
            lastObservedAt: waitedAt
        )
    }
}
