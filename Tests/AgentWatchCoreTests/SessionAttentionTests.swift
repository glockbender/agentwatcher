import AgentWatchTestSupport
import XCTest

@testable import AgentWatchCore

final class SessionAttentionTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_000)

    /// The table written out, rather than derived from the switch it is checking.
    ///
    /// Compilation already proves every phase is classified; what it cannot prove is that a
    /// phase is classified where a person would put it. A new phase added to `SessionPhase`
    /// fails the count assertion below rather than quietly joining whichever branch its
    /// author found convenient.
    func testEveryPhaseIsClassifiedWhereAPersonWouldPutIt() {
        let expected: [SessionPhase: SessionAttention] = [
            .waitingForUser: .needsPerson,
            .failed: .needsPerson,
            .terminalClosed: .needsPerson,
            .planning: .working,
            .executing: .working,
            .waitingForChildren: .working,
            .completed: .done,
            .idle: .quiet,
            .disconnected: .quiet,
            .sessionClosed: .closed,
        ]

        XCTAssertEqual(expected.count, SessionPhase.allCases.count, "a new phase needs a place in this table")
        for phase in SessionPhase.allCases {
            XCTAssertEqual(phase.attention, expected[phase], "\(phase.rawValue)")
        }
    }

    /// `claimsWork` moved from a switch of its own to a question about `attention`. The three
    /// phases it answers for are spelled out here so the move cannot have changed one.
    func testClaimsWorkAnswersExactlyAsBefore() {
        let claiming: Set<SessionPhase> = [.planning, .executing, .waitingForChildren]
        for phase in SessionPhase.allCases {
            XCTAssertEqual(phase.claimsWork, claiming.contains(phase), "\(phase.rawValue)")
        }
    }

    func testCountsTallyEachPhaseIntoItsOwnCell() {
        let counts = SessionAttentionCounts(sessions: [
            session(0, .waitingForUser),
            session(1, .failed),
            session(2, .executing),
            session(3, .planning),
            session(4, .waitingForChildren),
            session(5, .completed),
            session(6, .idle),
            session(7, .disconnected),
        ])

        XCTAssertEqual(counts, SessionAttentionCounts(needsPerson: 2, working: 3, done: 1, quiet: 2))
    }

    /// ADR-0002: a closed session is over, and the icon is about what is still going on.
    func testAClosedSessionIsCountedNowhere() {
        let counts = SessionAttentionCounts(sessions: [
            session(0, .sessionClosed),
            session(1, .sessionClosed),
            session(2, .executing),
        ])

        XCTAssertEqual(counts, SessionAttentionCounts(needsPerson: 0, working: 1, done: 0, quiet: 0))
        XCTAssertEqual(counts.counted, 1, "three sessions went in, one of them counts")
    }

    func testNoSessionsIsFourZeroesRatherThanNothing() {
        XCTAssertEqual(SessionAttentionCounts(sessions: []), .empty)
        XCTAssertEqual(SessionAttentionCounts.empty.counted, 0)
    }

    /// The reason this type is `Equatable`: what reads it redraws the menu bar, and most of
    /// what happens to a session does not move any of these four numbers.
    func testAChangeThatMovesNoCountComparesEqual() {
        let before = SessionAttentionCounts(sessions: [session(0, .planning), session(1, .idle)])
        let after = SessionAttentionCounts(sessions: [session(0, .executing), session(1, .idle)])

        XCTAssertEqual(before, after)
    }

    private func session(_ index: Int, _ phase: SessionPhase) -> SessionSnapshot {
        testSession(index: index, phase: phase, lastObservedAt: observed)
    }
}
