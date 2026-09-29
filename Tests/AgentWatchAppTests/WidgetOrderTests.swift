import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The order the widget shows its rows in, and the one moment it refuses to change it.
@MainActor
final class WidgetOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testTheRowsFollowTheOrderTheAppHandsOver() throws {
        let controller = try makeController()
        controller.order = { sessions, _ in sessions.sorted { $0.arrivalIndex > $1.arrivalIndex } }

        controller.render(WidgetState(sessions: [session(0), session(1), session(2)]))

        XCTAssertEqual(controller.shownOrder, [id(2), id(1), id(0)])
    }

    /// A row that moved while it was pointed at would move out from under the pointer, onto
    /// the next row's click. So the order waits, a newcomer goes to the end, and the real
    /// order arrives the moment the pointer leaves.
    func testTheRowsHoldTheirPlacesWhileThePointerIsOverTheWidget() throws {
        let controller = try makeController()
        var ordering = SessionOrdering()
        controller.order = { sessions, moment in
            ordering.order(sessions, mode: .recentActivity, blocks: SessionBlock.defaultOrder, now: moment)
        }
        controller.render(WidgetState(sessions: [session(0, at: now), session(1, at: now + 1)]))
        XCTAssertEqual(controller.shownOrder, [id(1), id(0)])

        controller.pointerEnteredWidget()
        controller.render(
            WidgetState(sessions: [session(0, at: now + 5), session(1, at: now + 1), session(2, at: now + 9)])
        )
        XCTAssertEqual(controller.shownOrder, [id(1), id(0), id(2)], "a row moved under the pointer")

        controller.pointerLeftWidget()
        XCTAssertEqual(controller.shownOrder, [id(2), id(0), id(1)], "the real order waited for the next event")
    }

    func testTheOrderIsStoredAndAnnounced() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        var announced = 0
        settings.onChange = { setting in
            if case .sessionOrder = setting {
                announced += 1
            }
        }
        XCTAssertEqual(settings.sessionOrder, .arrival, "the order where no row moves by itself")
        XCTAssertEqual(settings.sessionBlockOrder, SessionBlock.defaultOrder)

        settings.setSessionOrder(.blocks)
        settings.setSessionBlockOrder([.broken, .active, .closed, .inactive])

        let reopened = WidgetSettingsStore(preferences: preferences)
        XCTAssertEqual(reopened.sessionOrder, .blocks)
        XCTAssertEqual(reopened.sessionBlockOrder, [.broken, .active, .closed, .inactive])
        XCTAssertEqual(announced, 2)
    }

    /// Hand-edited files: a mode this version does not know is the default, and a block list
    /// missing a block gets it back.
    func testAnUnreadableOrderFallsBackRatherThanLosingSessions() throws {
        let preferences = try isolatedPreferences()
        preferences.set("byMood", forKey: "sessionOrder")
        preferences.set(["closed"], forKey: "sessionBlockOrder")

        let settings = WidgetSettingsStore(preferences: preferences)

        XCTAssertEqual(settings.sessionOrder, .arrival)
        XCTAssertEqual(settings.sessionBlockOrder, [.closed, .active, .inactive, .broken])
    }

    private func session(_ index: Int, at observed: Date? = nil) -> SessionSnapshot {
        testSession(index: index, title: "Session \(index)", phase: .idle, lastObservedAt: observed ?? now)
    }

    private func id(_ index: Int) -> String {
        "claude:session-\(index)"
    }

    private func makeController() throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in .nothingRaised },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.clock = { [now] in now }
        controller.showWindow(nil)
        addTeardownBlock { controller.close() }
        return controller
    }
}
