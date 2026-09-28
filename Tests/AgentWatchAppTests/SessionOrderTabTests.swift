import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The settings window's `Order` tab, operated the way a person does: set a control, send its
/// action, and read back what the tab shows and what it stored.
@MainActor
final class SessionOrderTabTests: XCTestCase {
    func testEveryOrderIsOfferedAndTheStoredOneIsChosen() throws {
        let (tab, settings) = try makeTab()
        settings.setSessionOrder(.recentActivity)
        tab.showCurrentValues()

        XCTAssertEqual(Set(tab.modeButtons.keys), Set(SessionOrder.allCases))
        XCTAssertEqual(tab.modeButtons.filter { $0.value.state == .on }.map(\.key), [.recentActivity])
    }

    func testChoosingAnOrderStoresItAndShowsWhatItDoes() throws {
        let (tab, settings) = try makeTab()

        try choose(.attention, in: tab)
        XCTAssertEqual(settings.sessionOrder, .attention)
        XCTAssertFalse(tab.preview.isHidden, "an order other than the blocks is shown as a list")

        try choose(.blocks, in: tab)
        XCTAssertEqual(settings.sessionOrder, .blocks)
        XCTAssertTrue(tab.preview.isHidden, "the blocks are shown as their builder, not as a list")
    }

    /// Every block, in the stored order, with the rows the widget itself would put in it —
    /// placed by `SessionBlock.of`, never by a list written for the builder.
    func testTheBuilderShowsEveryBlockWithTheRowsTheWidgetWouldPutInIt() throws {
        let (tab, settings) = try makeTab()
        settings.setSessionBlockOrder([.closed, .broken, .inactive, .active])
        try choose(.blocks, in: tab)
        let demo = SessionOrderDemo()

        for block in SessionBlock.allCases {
            let expected = demo.sessions.filter { SessionBlock.of($0, now: demo.now) == block }.map(\.id)
            XCTAssertEqual(Set(tab.builderRows[block] ?? []), Set(expected), "\(block)")
            XCTAssertFalse(expected.isEmpty, "\(block) has nothing to show")
        }
    }

    /// An arrow moves its block one place and the list follows; the arrows at the two ends
    /// are greyed rather than hidden, and say why.
    func testAnArrowMovesItsBlockAndTheEndsGoNoFurther() throws {
        let (tab, settings) = try makeTab()
        try choose(.blocks, in: tab)

        let up = try XCTUnwrap(tab.moveUpButtons[.inactive])
        up.sendAction(up.action, to: up.target)

        XCTAssertEqual(settings.sessionBlockOrder, [.inactive, .active, .broken, .closed])
        let top = try XCTUnwrap(tab.moveUpButtons[.inactive])
        XCTAssertFalse(top.isEnabled)
        XCTAssertEqual(top.toolTip, "This block is already at the top")
        let bottom = try XCTUnwrap(tab.moveDownButtons[.closed])
        XCTAssertFalse(bottom.isEnabled)
        XCTAssertEqual(bottom.toolTip, "This block is already at the bottom")
    }

    func testTheListPlaysOnlyWhileShownAndOnlyForAnOrderThatMovesRows() throws {
        let (tab, _) = try makeTab()
        tab.setShown(true)

        for order in SessionOrder.allCases {
            try choose(order, in: tab)
            XCTAssertEqual(tab.isPlaying, SessionOrderDemo.plays(order), "\(order)")
        }

        try choose(.recentActivity, in: tab)
        tab.setShown(false)
        XCTAssertFalse(tab.isPlaying, "the list plays where nobody can see it")
    }

    /// Each step shows exactly the order the widget would give the same sessions.
    func testEachStepShowsTheOrderTheWidgetWouldGive() throws {
        let (tab, _) = try makeTab()
        try choose(.attention, in: tab)
        var demo = SessionOrderDemo()
        var ordering = SessionOrdering()

        for _ in 0..<SessionOrderDemo.script.count {
            let expected = ordering.order(
                demo.sessions, mode: .attention, blocks: SessionBlock.defaultOrder, now: demo.now
            ).map(\.id)
            XCTAssertEqual(tab.preview.shownOrder, expected)
            tab.advanceDemo()
            demo.advance()
        }
    }

    /// Measured: two of the four explanations came out at half a point and drew darker than the
    /// other two in the same colour.
    func testTheExplanationsAreAWholeNumberOfPointsWide() throws {
        let (tab, _) = try makeTab()
        tab.view.layoutSubtreeIfNeeded()
        let grid = try XCTUnwrap(tab.view.arrangedSubviews.first as? NSGridView)

        for row in 0..<grid.numberOfRows {
            let label = try XCTUnwrap(grid.cell(atColumnIndex: 1, rowIndex: row).contentView)
            XCTAssertEqual(label.frame.width, label.frame.width.rounded(), "row \(row)")
        }
    }

    func testTheResetPutsBackTheArrivalOrderAndTheFirstBlockOrder() throws {
        let (tab, settings) = try makeTab()
        settings.setSessionOrder(.blocks)
        settings.setSessionBlockOrder([.closed, .broken, .inactive, .active])

        tab.resetOrder()

        XCTAssertEqual(settings.sessionOrder, .arrival)
        XCTAssertEqual(settings.sessionBlockOrder, SessionBlock.defaultOrder)
    }

    private func choose(_ order: SessionOrder, in tab: SessionOrderTab) throws {
        let button = try XCTUnwrap(tab.modeButtons[order])
        button.state = .on
        button.sendAction(button.action, to: button.target)
    }

    func testRefreshingTheOrderPreviewAppliesAChangedRowLayout() throws {
        let preferences = try isolatedPreferences()
        let layouts = RowLayoutStore(preferences: preferences)
        let tab = SessionOrderTab(
            settings: WidgetSettingsStore(preferences: preferences),
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: LampSchemeStore(preferences: preferences), rowLayouts: layouts)
        func lamps(in view: NSView) -> Int {
            (view is SessionLampView ? 1 : 0) + view.subviews.reduce(0) { $0 + lamps(in: $1) }
        }
        XCTAssertGreaterThan(lamps(in: tab.preview), 0)

        layouts.setLayout(layouts.layout.changing(parts: layouts.layout.parts.filter { $0 != .lamp }))
        tab.showCurrentValues()

        XCTAssertEqual(lamps(in: tab.preview), 0, "the rows still use the previous layout")
    }

    private func makeTab() throws -> (SessionOrderTab, WidgetSettingsStore) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let tab = SessionOrderTab(
            settings: settings,
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: LampSchemeStore(preferences: preferences),
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        addTeardownBlock { tab.setShown(false) }
        return (tab, settings)
    }
}
