import AppKit
import XCTest

@testable import AgentWatchApp

/// The rule behind the two `+N` counters, stated over rectangles.
///
/// Its own file, beside `HUDOverflowTests`, which measures the same rule on a list that is
/// really laid out. The two are halves of one subject and this half spent a while inside the
/// tests about locking the window, where nobody looking for it would think to read.
///
/// The counters exist precisely for the case where the scrollers have auto-hidden.
final class HiddenRowCountTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 300, height: 100)
    /// Scrolled down by two rows: the first two are past the top edge, and the view reaches
    /// further down by the same amount.
    private let scrolledDown = NSRect(x: 0, y: 64, width: 300, height: 100)

    func testNothingIsHiddenWhenEveryRowFits() {
        XCTAssertEqual(hiddenRows(rowFrames: rows(3), visibleRect: visible), .none)
    }

    func testRowsBelowTheFoldAreCounted() {
        XCTAssertEqual(hiddenRows(rowFrames: rows(6), visibleRect: visible), HiddenRows(above: 0, below: 3))
    }

    /// The reason there are two counts. A list scrolled down has sessions behind it as well
    /// as ahead of it, and one number cannot say which — the counter used to add both
    /// together and announce read sessions under an arrow pointing at nothing.
    func testRowsPastTheTopEdgeAreCountedSeparately() {
        XCTAssertEqual(hiddenRows(rowFrames: rows(6), visibleRect: scrolledDown), HiddenRows(above: 2, below: 1))
    }

    func testARowMostlyPastTheFoldIsHidden() {
        let straddling = NSRect(x: 0, y: 90, width: 300, height: 30)

        XCTAssertEqual(hiddenRows(rowFrames: [straddling], visibleRect: visible), HiddenRows(above: 0, below: 1))
    }

    /// The same rule at the other edge: a row mostly past the top is a row there is more of
    /// to scroll back to.
    func testARowMostlyPastTheTopEdgeIsHidden() {
        let straddling = NSRect(x: 0, y: 50, width: 300, height: 30)

        XCTAssertEqual(hiddenRows(rowFrames: [straddling], visibleRect: scrolledDown), HiddenRows(above: 1, below: 0))
    }

    /// The complaint this answers: a last row clipped by a point or two was counted, so the
    /// widget stood there promising something below while the only thing below was the bottom
    /// sliver of a line already in front of the reader.
    func testARowBarelyPastTheFoldIsNotHidden() {
        let barely = NSRect(x: 0, y: 82, width: 300, height: 20)

        XCTAssertEqual(hiddenRows(rowFrames: [barely], visibleRect: visible), .none, "2 points of 20 is readable")
    }

    func testARowBarelyPastTheTopEdgeIsNotHidden() {
        let barely = NSRect(x: 0, y: 62, width: 300, height: 20)

        XCTAssertEqual(hiddenRows(rowFrames: [barely], visibleRect: scrolledDown), .none, "2 points of 20")
    }

    /// Exactly on the line, both ways round. Heights picked so the arithmetic is exact:
    /// 30 % of 20 points is 6, so 6 points over is still readable and 6.5 is not. Without
    /// this pair a later change of the fraction would slide past every other test here.
    func testTheFractionOfARowThatMayHangOffIsExact() {
        let onTheLine = NSRect(x: 0, y: 86, width: 300, height: 20)
        let justPast = NSRect(x: 0, y: 86.5, width: 300, height: 20)

        XCTAssertEqual(hiddenRows(rowFrames: [onTheLine], visibleRect: visible), .none, "6 points of 20 exactly")
        XCTAssertEqual(
            hiddenRows(rowFrames: [justPast], visibleRect: visible),
            HiddenRows(above: 0, below: 1),
            "6.5 points of 20"
        )
    }

    func testTheFractionOfARowThatMayHangOffTheTopIsExact() {
        let onTheLine = NSRect(x: 0, y: 58, width: 300, height: 20)
        let justPast = NSRect(x: 0, y: 57.5, width: 300, height: 20)

        XCTAssertEqual(hiddenRows(rowFrames: [onTheLine], visibleRect: scrolledDown), .none, "6 points of 20 exactly")
        XCTAssertEqual(
            hiddenRows(rowFrames: [justPast], visibleRect: scrolledDown),
            HiddenRows(above: 1, below: 0),
            "6.5 points of 20"
        )
    }

    /// A row wider than the clip view is reached by scrolling sideways, not hidden. Counting
    /// it made the widget report missing sessions while every one of them was on screen, and
    /// made widening the window change a count that is about vertical space.
    func testARowWiderThanTheViewIsNotHidden() {
        let wide = NSRect(x: 0, y: 0, width: 900, height: 24)

        XCTAssertEqual(hiddenRows(rowFrames: [wide], visibleRect: visible), .none)
    }

    func testAHorizontallyScrolledViewStillHidesNothingVertically() {
        let scrolledRight = NSRect(x: 200, y: 0, width: 300, height: 100)

        XCTAssertEqual(hiddenRows(rowFrames: rows(3), visibleRect: scrolledRight), .none)
    }

    /// Row frames land on fractional coordinates, so one ending flush with the fold must not
    /// be rounded into the hidden set.
    func testARowEndingExactlyAtTheFoldIsVisible() {
        let flush = NSRect(x: 0, y: 76, width: 300, height: 24)

        XCTAssertEqual(hiddenRows(rowFrames: [flush], visibleRect: visible), .none)
    }

    /// And the mirror of it: a row starting flush with the top edge is in view, not above it.
    func testARowStartingExactlyAtTheTopEdgeIsVisible() {
        let flush = NSRect(x: 0, y: 64, width: 300, height: 24)

        XCTAssertEqual(hiddenRows(rowFrames: [flush], visibleRect: scrolledDown), .none)
    }

    func testAnEmptyListHidesNothing() {
        XCTAssertEqual(hiddenRows(rowFrames: [], visibleRect: visible), .none)
    }

    private func rows(_ count: Int) -> [NSRect] {
        (0..<count).map { NSRect(x: 0, y: CGFloat($0) * 32, width: 300, height: 24) }
    }
}
