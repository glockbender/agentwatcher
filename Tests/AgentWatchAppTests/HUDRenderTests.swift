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

        controller.render(WidgetState(complaint: "Install hooks from Tooling in Settings."))

        XCTAssertTrue(
            visibleText(of: controller).contains("Install hooks from Tooling in Settings."),
            "the widget shows: \(visibleText(of: controller))"
        )
    }

    /// And it keeps up: installing the hooks while the widget is empty changes what it should
    /// say, with no session arriving to force the redraw.
    func testAChangedComplaintReplacesTheOneOnScreen() throws {
        let controller = try makeController()
        controller.render(WidgetState(complaint: "Install hooks from Tooling in Settings."))

        controller.render(WidgetState(complaint: nil))

        XCTAssertTrue(
            visibleText(of: controller).contains("No active sessions"),
            "the widget shows: \(visibleText(of: controller))"
        )
    }

    /// The shadow of a window that is not opaque is cut from what the window shows, and the
    /// window server does not cut it again when the content changes at the same size. The first
    /// empty state, replaced by a row at the same 340×56, stayed readable through the backdrop
    /// under that row.
    func testAChangeOfContentAsksForANewShadow() throws {
        let controller = try makeController()
        controller.render(WidgetState(complaint: "Install hooks from Tooling in Settings."))
        let panel = try XCTUnwrap(controller.window as? HUDPanel)
        let before = panel.shadowsRemade

        controller.render(WidgetState(sessions: [testSession(title: "Сессия", lastObservedAt: now)]))

        XCTAssertGreaterThan(panel.shadowsRemade, before, "the content changed, and the shadow stayed the old one")
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

    func testNavigationStaysReachableWithAndWithoutSessionsAndWithTheWidgetLocked() throws {
        for scale in [0.5, 1, 2.0] {
            for locked in [false, true] {
                let controller = try makeController(show: false, scale: scale, locked: locked)
                let panel = try XCTUnwrap(controller.window)
                let view = try XCTUnwrap(panel.contentView)
                panel.setContentSize(WidgetStyle(scale: scale).minimumWindowSize)
                var opened: [String] = []
                controller.openProjects = { opened.append("Projects") }
                controller.openSettings = { opened.append("Settings") }
                for state in [
                    WidgetState(), WidgetState(sessions: [testSession(title: "session", lastObservedAt: now)]),
                    WidgetState(complaint: "Connect an agent to start watching sessions"),
                ] {
                    controller.render(state)
                    view.layoutSubtreeIfNeeded()
                    for title in ["Projects", "Settings"] {
                        let button = try XCTUnwrap(button(named: title, in: view))
                        XCTAssertEqual(button.accessibilityLabel(), "Open " + title)
                        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
                        XCTAssertFalse(button.mouseDownCanMoveWindow)
                        let bounds = button.convert(button.bounds, to: view)
                        XCTAssertTrue(
                            view.bounds.contains(bounds), "\(title) at \(scale)x: \(bounds) in \(view.bounds)")
                        let center = NSPoint(x: bounds.midX, y: bounds.midY)
                        XCTAssertTrue(view.hitTest(center) === button, "\(title) behind an overlay")
                        button.performClick(nil)
                    }
                    XCTAssertEqual(opened, ["Projects", "Settings"])
                    opened.removeAll()
                }
                controller.shutdown()
            }
        }
    }

    private func button(named title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.button(named: title, in: $0) }.first
    }

    private func makeController(show: Bool = true, scale: CGFloat = 1, locked: Bool = false) throws
        -> HUDPanelController
    {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let settings = WidgetSettingsStore(preferences: preferences)
        settings.setLocksPosition(locked)
        settings.setLocksSize(locked)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in .nothingRaised },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            style: WidgetStyle(scale: scale),
            frameStore: frameStore,
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        if show { controller.showWindow(nil) }
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
