import AgentWatchTestSupport
import XCTest

@testable import AgentWatchCore

final class SessionFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testWorkingSessionTransitionsFromCurrentToQuietThenNoRecentActivity() {
        let session = snapshot(phase: .executing)

        XCTAssertEqual(
            SessionFreshnessEvaluator.evaluate(session, now: start.addingTimeInterval(14)),
            .current
        )
        XCTAssertEqual(
            SessionFreshnessEvaluator.evaluate(session, now: start.addingTimeInterval(15)),
            .quiet
        )
        XCTAssertEqual(
            SessionFreshnessEvaluator.evaluate(session, now: start.addingTimeInterval(60)),
            .noRecentActivity
        )
    }

    func testUserAndCompletedStatesNeverBecomeStale() {
        for phase in [SessionPhase.waitingForUser, .completed, .sessionClosed] {
            XCTAssertEqual(
                SessionFreshnessEvaluator.evaluate(
                    snapshot(phase: phase),
                    now: start.addingTimeInterval(600)
                ),
                .current
            )
        }
    }

    private func snapshot(phase: SessionPhase) -> SessionSnapshot {
        testSession(phase: phase, lastObservedAt: start)
    }
}
