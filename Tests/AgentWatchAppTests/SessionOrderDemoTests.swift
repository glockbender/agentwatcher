import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The made-up list the settings window plays. It has to be worth watching: a loop that
/// returns to its start, a block for every session kind, and movement exactly in the orders
/// that move rows.
final class SessionOrderDemoTests: XCTestCase {
    /// Played forever, so the last step has to leave the list where the first began.
    func testTheScriptEndsWhereItBegan() {
        var demo = SessionOrderDemo()
        let start = demo.sessions.map(\.phase)

        for _ in SessionOrderDemo.script {
            demo.advance()
        }

        XCTAssertEqual(demo.sessions.map(\.phase), start)
    }

    func testEveryStepChangesOneSession() {
        var demo = SessionOrderDemo()
        for step in SessionOrderDemo.script.indices {
            let before = demo.sessions.map(\.phase)
            demo.advance()
            let changed = zip(before, demo.sessions.map(\.phase)).filter { $0 != $1 }.count
            XCTAssertEqual(changed, 1, "step \(step)")
        }
    }

    func testEveryBlockHasSomethingInIt() {
        let demo = SessionOrderDemo()

        let blocks = Set(demo.sessions.map { SessionBlock.of($0, now: demo.now) })

        XCTAssertEqual(blocks, Set(SessionBlock.allCases))
    }

    /// The animation is there to show rows moving. In the arrival order nothing moves by
    /// itself, and the demo must show exactly that; in the two others something has to move.
    func testRowsMoveInTheOrdersThatMoveThemAndOnlyThere() {
        for mode in SessionOrder.allCases {
            var demo = SessionOrderDemo()
            var ordering = SessionOrdering()
            var orders: [[String]] = []
            for _ in 0...SessionOrderDemo.script.count {
                orders.append(
                    ordering.order(demo.sessions, mode: mode, blocks: SessionBlock.defaultOrder, now: demo.now)
                        .map(\.id))
                demo.advance()
            }
            let moves = zip(orders, orders.dropFirst()).filter { $0 != $1 }.count
            switch mode {
            case .arrival:
                XCTAssertEqual(moves, 0, "a row moved in the arrival order")
                XCTAssertFalse(SessionOrderDemo.plays(mode))
            case .recentActivity, .attention:
                XCTAssertTrue(SessionOrderDemo.plays(mode))
                XCTAssertGreaterThan(moves, 2, "\(mode) shows too little to be worth playing")
            case .blocks:
                // Shown as the builder instead: its rows move only when a person moves a block.
                XCTAssertFalse(SessionOrderDemo.plays(mode))
                XCTAssertGreaterThan(moves, 0)
            }
        }
    }
}
