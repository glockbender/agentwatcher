import AgentWatchTestSupport
import XCTest

@testable import AgentWatchCore

/// Headless runs: hidden by default and shown on request, with nothing else touched by either
/// answer, and a run a person asked to end goes when it ends (ADR-0021).
final class HeadlessRunsTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_791_418_000)

    func testOnlyHeadlessRunsAreHiddenAndTheOrderIsKept() {
        let sessions = [
            testSession(index: 0, clientKind: .cli, lastObservedAt: moment),
            testSession(index: 1, source: .codex, clientKind: .headless, lastObservedAt: moment),
            testSession(index: 2, clientKind: .desktop, lastObservedAt: moment),
            testSession(index: 3, clientKind: .headless, lastObservedAt: moment),
            testSession(index: 4, clientKind: .background, lastObservedAt: moment),
            testSession(index: 5, clientKind: nil, lastObservedAt: moment),
        ]

        XCTAssertEqual(
            sessions.shown(includingHeadlessRuns: false).map(\.id),
            [0, 2, 4, 5].map { sessions[$0].id }
        )
        XCTAssertEqual(sessions.shown(includingHeadlessRuns: true), sessions)
    }

    /// A run is at work when a person asks to end it, where a broken session waits: the rule
    /// that forgets a row gone back to work would forget every run at once.
    func testARunAskedToEndGoesWhenItEndsThoughItWasAtWork() throws {
        var engine = SessionStateEngine()
        try engine.ingest(runEvent(.sessionStarted, at: moment))
        let row = try engine.ingest(runEvent(.turnStarted, at: moment + 1))
        engine.removeWhenClosed(id: row.id)

        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [], "the run has not ended yet")
        XCTAssertEqual(engine.takeRowsEndedAsAsked(), [], "and the request is still held")
        XCTAssertNotNil(engine.snapshots[row.id])

        try engine.ingest(runEvent(.sessionEnded, at: moment + 2))

        XCTAssertEqual(engine.takeRowsEndedAsAsked().map(\.id), [row.id])
        XCTAssertNil(engine.snapshots[row.id])
    }

    private func runEvent(_ kind: EventKind, at observedAt: Date) -> EventEnvelope {
        testEvent(sessionLabel: "run", kind: kind, observedAt: observedAt, agentProcessID: 7_220, clientKind: .headless)
    }
}
