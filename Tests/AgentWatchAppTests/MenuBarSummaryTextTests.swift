import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The words the menu, the tooltip and a screen reader all get.
final class MenuBarSummaryTextTests: XCTestCase {
    func testEveryCellThatHoldsSomethingIsNamed() {
        let line = MenuBarSummaryText.line(
            for: SessionAttentionCounts(needsPerson: 2, working: 3, done: 1, quiet: 4)
        )

        XCTAssertEqual(line, "2 need you · 3 working · 1 done · 4 idle")
    }

    /// The icon shows a zero to hold the cell's place; a sentence has no places to hold.
    func testACellHoldingNothingIsLeftOut() {
        let line = MenuBarSummaryText.line(
            for: SessionAttentionCounts(needsPerson: 0, working: 2, done: 0, quiet: 0)
        )

        XCTAssertEqual(line, "2 working")
    }

    func testOneSessionWaitingIsSaidInTheSingular() {
        let line = MenuBarSummaryText.line(
            for: SessionAttentionCounts(needsPerson: 1, working: 0, done: 0, quiet: 0)
        )

        XCTAssertEqual(line, "1 needs you")
    }

    /// The same words the widget uses with nothing to show, so the two cannot disagree about
    /// what "nothing" is called.
    func testNothingRunningIsSaidTheWayTheWidgetSaysIt() {
        XCTAssertEqual(MenuBarSummaryText.line(for: .empty), "No active sessions")
    }
}
