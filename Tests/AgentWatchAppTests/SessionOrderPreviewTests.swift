import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The Order page's made-up list: what it plays, when, and that it is drawn in the look and
/// the row the rest of the window has chosen.
@MainActor
final class SessionOrderPreviewTests: XCTestCase {
    func testEveryOrderIsOfferedWithWhatItDoes() {
        XCTAssertEqual(Set(SessionOrder.allCases.map(\.settingsTitle)).count, SessionOrder.allCases.count)
        for order in SessionOrder.allCases {
            XCTAssertFalse(order.settingsExplanation.isEmpty, "\(order)")
        }
    }

    func testTheListPlaysOnlyWhileShownAndOnlyForAnOrderThatMovesRows() throws {
        let (tab, settings, _) = try makeTab()
        tab.setShown(true)

        for order in SessionOrder.allCases {
            settings.setSessionOrder(order)
            tab.showCurrentValues()
            XCTAssertEqual(tab.isPlaying, SessionOrderDemo.plays(order), "\(order)")
        }

        settings.setSessionOrder(.recentActivity)
        tab.showCurrentValues()
        OrderPreview.dismantleNSView(NSView(), coordinator: tab)
        XCTAssertFalse(tab.isPlaying, "the list plays on a page nobody can see")
    }

    /// Each step shows exactly the order the widget would give the same sessions.
    func testEachStepShowsTheOrderTheWidgetWouldGive() throws {
        let (tab, settings, _) = try makeTab()
        settings.setSessionOrder(.attention)
        tab.showCurrentValues()
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

    func testShowingThePreviewAgainAppliesAChangedRowLayout() throws {
        let (tab, _, layouts) = try makeTab()
        XCTAssertGreaterThan(Self.lamps(in: tab.preview).count, 0)

        layouts.setLayout(layouts.layout.changing(parts: layouts.layout.parts.filter { $0 != .lamp }))
        tab.showCurrentValues()

        XCTAssertEqual(Self.lamps(in: tab.preview).count, 0, "the rows still use the previous layout")
    }

    /// The lamps are chosen on another page, and the demo's sessions have not changed when the
    /// preview is shown again: every row is drawn anew all the same.
    func testNewLampsAreDrawnEvenWhenTheDemoIsUnchanged() throws {
        var look = WidgetTheme.standard.dark
        let (tab, settings, _) = try makeTab(look: { look })
        for order: SessionOrder in [.arrival, .attention, .recentActivity] {
            settings.setSessionOrder(order)
            tab.showCurrentValues()
            let chosen = Self.lamps(in: tab.preview).first?.paintedColor?.srgbHex == "#123456" ? "#654321" : "#123456"
            for phase in SessionPhase.allCases {
                look.setLampStyle(LampStyle(color: NSColor(sRGB: chosen), motion: .steady), for: phase)
            }

            tab.showCurrentValues()

            let shown = Self.lamps(in: tab.preview)
            XCTAssertEqual(shown.count, SessionOrderDemo().sessions.count)
            for lamp in shown {
                XCTAssertEqual(lamp.paintedColor?.srgbHex, chosen, "\(order)")
                XCTAssertFalse(lamp.isBlinking, "\(order)")
            }
        }
    }

    /// The panel under the rows is the widget's, and it follows a theme changed on another page.
    func testTheBackgroundIsDrawnAgainWhenThePreviewIsShownAgain() throws {
        var background = WidgetBackground.graphite
        let (tab, _, _) = try makeTab(background: { background })
        let before = try XCTUnwrap(tab.preview.subviews.compactMap { $0 as? Backdrop }.first)

        background = .pearl
        tab.showCurrentValues()

        let after = try XCTUnwrap(tab.preview.subviews.compactMap { $0 as? Backdrop }.first)
        XCTAssertFalse(after === before, "the preview still stands on the panel it was first drawn on")
        XCTAssertEqual(tab.preview.subviews.compactMap { $0 as? Backdrop }.count, 1)
    }

    func testTheResetPutsBackTheArrivalOrderAndTheFirstBlockOrder() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        let model = SettingsModel(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        settings.setSessionOrder(.blocks)
        settings.setSessionBlockOrder([.closed, .broken, .inactive, .active])

        model.restoreOrderDefaults()

        XCTAssertEqual(settings.sessionOrder, .arrival)
        XCTAssertEqual(settings.sessionBlockOrder, SessionBlock.defaultOrder)
    }

    private func makeTab(
        look: @escaping () -> WidgetTheme.Look = { WidgetTheme.standard.dark },
        background: @escaping () -> WidgetBackground = { .graphite }
    ) throws -> (OrderPreviewPlayer, WidgetSettingsStore, RowLayoutStore) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let layouts = RowLayoutStore(preferences: preferences)
        let tab = OrderPreviewPlayer(
            settings: settings, look: look, background: background, opacity: { 1 }, rowLayouts: layouts)
        addTeardownBlock { tab.setShown(false) }
        return (tab, settings, layouts)
    }

    private static func lamps(in view: NSView) -> [SessionLampView] {
        (view as? SessionLampView).map { [$0] } ?? view.subviews.flatMap(lamps)
    }
}
