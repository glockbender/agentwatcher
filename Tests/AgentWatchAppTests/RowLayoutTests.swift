import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The template a row is drawn from, and the four rules it is not allowed to break.
///
/// The rules are checked on the value rather than on a drawn row, which is the whole reason
/// `RowLayout` is a value: a row that broke one of them would be found by eye, once, on the
/// widget of whoever happened to look — see ADR-0011.
final class RowLayoutTests: XCTestCase {
    /// Everything before the gap is packed to the left and everything after it sits at the
    /// right edge, so a template without one has no right edge at all.
    func testATemplateWithNoGapGetsOneAtItsEnd() {
        let layout = RowLayout(parts: [.timer, .lamp, .name])

        XCTAssertEqual(layout.parts, [.timer, .lamp, .name, .gap])
    }

    /// A second gap would be a second place for the row's slack to collect, and then neither
    /// of them holds the right edge. The first one wins because it is the one a person put
    /// there first.
    func testASecondGapIsDropped() {
        let layout = RowLayout(parts: [.timer, .gap, .name, .gap, .context])

        XCTAssertEqual(layout.parts, [.timer, .gap, .name, .context])
    }

    /// A part drawn twice is a row saying the same thing twice, and the second copy pushes
    /// everything after it along for no gain. Hand-edited files are where these come from.
    func testAPartNamedTwiceIsKeptOnlyWhereItFirstStands() {
        let layout = RowLayout(parts: [.timer, .name, .gap, .name, .context])

        XCTAssertEqual(layout.parts, [.timer, .name, .gap, .context])
    }

    /// The template a fresh install gets draws exactly the row this app drew before the row
    /// became configurable. Stated as a test because it is a promise to everyone updating:
    /// nothing moves until they move it.
    func testTheDefaultTemplateIsTheRowTheAppAlwaysDrew() {
        let layout = RowLayout.standard

        XCTAssertEqual(layout.parts, [.timer, .lamp, .agent, .fault, .name, .gap, .counters, .context])
        XCTAssertEqual(layout.flexible, .name)
    }

    /// Asked by the hover card, which must not name a session whose rows have stopped naming
    /// it, and by the settings window. One question, one answer, no second flag.
    func testATemplateSaysWhetherItDrawsAPart() {
        let layout = RowLayout(parts: [.timer, .lamp, .gap, .context])

        XCTAssertFalse(layout.shows(.name))
        XCTAssertTrue(layout.shows(.context))
    }

    // MARK: - Which counters the block draws

    func testTheKindsOfCounterAreKeptAsChosen() {
        let layout = RowLayout(parts: [.counters, .gap], counterKinds: [.shell, .tool])

        XCTAssertEqual(layout.counterKinds, [.shell, .tool])
    }

    /// Every kind switched off leaves a part that draws nothing and cannot say why — it looks
    /// exactly like a session with no work. Fail open, the way monitoring does: a block with
    /// nothing chosen counts everything, and a person who wants none removes the part.
    func testACounterBlockWithNoKindsChosenCountsThemAll() {
        let layout = RowLayout(parts: [.counters, .gap], counterKinds: [])

        XCTAssertEqual(layout.counterKinds, Set(ActivityKind.allCases))
    }

    // MARK: - The one part that gives way

    func testThePartChosenToGiveWayIsKept() {
        let layout = RowLayout(parts: [.timer, .name, .branch, .gap], flexible: .branch)

        XCTAssertEqual(layout.flexible, .branch)
    }

    /// Removing a part in the settings window leaves the choice behind pointing at nothing.
    /// A row with no part that gives way does not narrow — it scrolls sideways.
    func testAPartThatGivesWayButIsNotInTheTemplateIsReplacedByTheFirstThatCan() {
        let layout = RowLayout(parts: [.timer, .name, .gap], flexible: .branch)

        XCTAssertEqual(layout.flexible, .name)
    }

    /// A lamp is nine points wide whatever happens to it. Only a part made of text has
    /// anything to give up, and a hand-edited file is free to name one that has not.
    func testAPartWithNothingToGiveUpCannotBeTheOneThatGivesWay() {
        let layout = RowLayout(parts: [.timer, .lamp, .name, .gap], flexible: .lamp)

        XCTAssertEqual(layout.flexible, .name)
    }

    /// A template of nothing but fixed widths. The row then keeps its own width and the
    /// widget clips it, which is honest: there is nothing in it that could have given way.
    func testATemplateOfFixedWidthsHasNoPartThatGivesWay() {
        let layout = RowLayout(parts: [.timer, .lamp, .gap, .context], flexible: .name)

        XCTAssertNil(layout.flexible)
    }
}
