import AgentWatchCore
import AgentWatchTestSupport
import XCTest

/// Headless runs are hidden by default and shown on request, and nothing else is touched by
/// either answer (ADR-0021).
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
}
