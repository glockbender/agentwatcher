import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The widget has one input, and everything it shows arrives through it.
///
/// It used to have two: the sessions came through `update(sessions:usageLimits:)`, which
/// compared and redrew, and the tooling complaint was assigned to a property that did
/// neither. The two drifted apart exactly where it mattered most — a fresh install with
/// nothing able to report said "No active sessions" instead of saying what to install, and
/// only corrected itself when something unrelated forced a redraw.
@MainActor
final class HUDRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// The first frame of a fresh install. Nothing has ever reported, so nothing else will
    /// redraw the widget — if the complaint does not arrive with the state, it is never seen.
    func testTheComplaintIsOnScreenBeforeAnySessionArrives() throws {
        let controller = try makeController()

        controller.render(WidgetState(complaint: "Install hooks from Tooling in the menu."))

        XCTAssertTrue(
            visibleText(of: controller).contains("Install hooks from Tooling in the menu."),
            "the widget shows: \(visibleText(of: controller))"
        )
    }

    /// And it keeps up: installing the hooks while the widget is empty changes what it should
    /// say, with no session arriving to force the redraw.
    func testAChangedComplaintReplacesTheOneOnScreen() throws {
        let controller = try makeController()
        controller.render(WidgetState(complaint: "Install hooks from Tooling in the menu."))

        controller.render(WidgetState(complaint: nil))

        XCTAssertTrue(
            visibleText(of: controller).contains("No active sessions"),
            "the widget shows: \(visibleText(of: controller))"
        )
    }

    /// The guard that keeps the row under the pointer alive: a report that changes nothing
    /// must not rebuild anything.
    func testAStateThatChangedNothingKeepsTheRowItAlreadyBuilt() throws {
        let controller = try makeController()
        let state = WidgetState(sessions: [testSession(title: "Сессия", lastObservedAt: now)])
        controller.render(state)
        let row = try XCTUnwrap(controller.currentRow(for: state.sessions[0].id))

        controller.render(state)

        XCTAssertTrue(
            controller.currentRow(for: state.sessions[0].id) === row,
            "the same report rebuilt the row"
        )
    }

    private func makeController() throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences)
        )
        controller.showWindow(nil)
        return controller
    }

    /// Every word the widget is currently drawing, read off the views themselves — the one
    /// way to tell "the value was assigned" from "the person can see it".
    private func visibleText(of controller: HUDPanelController) -> [String] {
        guard let contentView = controller.window?.contentView else {
            return []
        }
        return labels(in: contentView)
    }

    private func labels(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }
}
