import XCTest

@testable import AgentWatchCore

final class CodexQuestionStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1234)
    private func event(_ kind: EventKind, after seconds: TimeInterval, activity: String? = nil) -> EventEnvelope {
        EventEnvelope(
            source: .codex, sessionID: "thread", activityID: activity, observedAt: start + seconds, kind: kind)
    }

    func testQuestionsOutliveDeliveryOtherWorkAndPartialReplies() throws {
        var engine = SessionStateEngine()
        let id = try XCTUnwrap(engine.ingest(event(.turnStarted, after: 0))).id
        engine.apply(.codexQuestionAsked(activityID: "first", at: start + 1), toSessionWithID: id)
        engine.apply(.codexQuestionAsked(activityID: "second", at: start + 1), toSessionWithID: id)
        engine.apply(.callReturned(activityID: "first", at: start + 2), toSessionWithID: id)
        try engine.ingest(event(.activityStarted, after: 3, activity: "shell"))
        XCTAssertTrue(try XCTUnwrap(engine.snapshots[id]).needsUserReply)
        try engine.ingest(event(.turnCompleted, after: 4))
        engine.apply(.codexQuestionAnswered(activityID: "first", at: start + 5), toSessionWithID: id)
        XCTAssertEqual(engine.snapshots[id]?.attention, .needsPerson)
        engine.apply(.codexQuestionAnswered(activityID: "second", at: start + 6), toSessionWithID: id)
        XCTAssertEqual(engine.snapshots[id]?.phase, .completed)
        XCTAssertEqual(engine.snapshots[id]?.attention, .done)
    }

    func testCancelledQuestionCannotReopenFromALateRead() throws {
        var engine = SessionStateEngine()
        let id = try XCTUnwrap(engine.ingest(event(.turnStarted, after: 0))).id
        engine.apply(.codexQuestionAsked(activityID: "question", at: start + 1), toSessionWithID: id)
        try engine.ingest(event(.turnInterrupted, after: 2))
        engine.apply(.codexQuestionAsked(activityID: "question", at: start + 1), toSessionWithID: id)
        XCTAssertFalse(try XCTUnwrap(engine.snapshots[id]).needsUserReply)
    }
    func testEarlierInterruptionDoesNotClearANewerQuestionOrRewindTheCutoff() throws {
        var engine = SessionStateEngine()
        let id = try engine.ingest(event(.turnStarted, after: 0)).id
        engine.apply(.codexQuestionAsked(activityID: "newer", at: start + 3), toSessionWithID: id)
        try engine.ingest(event(.turnInterrupted, after: 2))
        XCTAssertTrue(try XCTUnwrap(engine.snapshots[id]).needsUserReply)
        try engine.ingest(event(.turnInterrupted, after: 5))
        try engine.ingest(event(.turnInterrupted, after: 2))
        engine.apply(.codexQuestionAsked(activityID: "stale", at: start + 5), toSessionWithID: id)
        XCTAssertFalse(try XCTUnwrap(engine.snapshots[id]).needsUserReply)
    }

    func testRestartRestoresOnlyQuestionsStillOpenInTheTranscript() throws {
        var engine = SessionStateEngine()
        let id = try engine.ingest(event(.turnStarted, after: 0)).id
        let first = TranscriptFact.codexQuestionAsked(activityID: "first", at: start + 1)
        let second = TranscriptFact.codexQuestionAsked(activityID: "second", at: start + 2)
        engine.apply(first, toSessionWithID: id)
        engine.apply(second, toSessionWithID: id)
        let history = SessionHistory.records(of: engine.snapshots.values)
        var restored = SessionStateEngine()
        XCTAssertFalse(try XCTUnwrap(restored.restore(history).first).needsUserReply)
        let evidence = SessionHistory.RememberedWaitEvidence(
            facts: [first, second, .codexQuestionAnswered(activityID: "first", at: start + 3)], dialogs: [])
        let row = try XCTUnwrap(restored.confirmRememberedWait(forSessionWithID: id, evidence: evidence))
        XCTAssertTrue(row.needsUserReply)
        XCTAssertEqual(row.pendingCodexQuestions, ["second": start + 2])
        restored.apply(.codexQuestionAnswered(activityID: "second", at: start + 6), toSessionWithID: id)
        XCTAssertFalse(try XCTUnwrap(restored.snapshots[id]).needsUserReply)
    }

}
