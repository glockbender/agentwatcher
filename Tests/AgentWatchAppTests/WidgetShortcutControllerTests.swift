import AppKit
import XCTest

@testable import AgentWatchApp

/// The part of the shortcut that can be checked without a keyboard: what gets registered, in
/// what order, and what the person is told when the machine says no.
@MainActor
final class WidgetShortcutControllerTests: XCTestCase {
    func testTheStoredShortcutGoesUpWhenTheAppStarts() throws {
        let (controller, registrar, _) = try makeController()

        controller.apply()

        XCTAssertEqual(registrar.calls, [.register("opt+cmd+13")])
        XCTAssertEqual(controller.status, .active(try optionCommandW()))
    }

    /// The system's table of shortcuts counts our own registration, and — measured — only our
    /// own: two applications hold the same combination quite happily, but one application asking
    /// twice is refused. So putting the new combination up before taking the old one down is the
    /// one way this app can collide with anything at all.
    func testTheOldCombinationComesDownBeforeTheNewOneGoesUp() throws {
        let (controller, registrar, settings) = try makeController()
        controller.apply()
        registrar.forgetCalls()

        settings.setToggleShortcut(WidgetShortcut(keyCode: 96, modifiers: [.control]))
        controller.apply()

        XCTAssertEqual(registrar.calls, [.unregister, .register("ctrl+96")])
    }

    func testClearingTheShortcutTakesItDownAndLeavesNothing() throws {
        let (controller, registrar, settings) = try makeController()
        controller.apply()
        registrar.forgetCalls()

        settings.setToggleShortcut(nil)
        controller.apply()

        XCTAssertEqual(registrar.calls, [.unregister])
        XCTAssertEqual(controller.status, WidgetShortcutController.Status.none)
    }

    /// Fail-open: the app carries on, and the setting keeps the combination the person chose so
    /// the settings window can say which one it is that will not take.
    func testARefusedRegistrationIsReportedRatherThanSwallowed() throws {
        let (controller, registrar, _) = try makeController()
        registrar.answer = .alreadyOurs

        controller.apply()

        XCTAssertEqual(controller.status, .alreadyOurs(try optionCommandW()))
    }

    func testPressingTheShortcutHidesAndShowsTheWidget() throws {
        let toggles = Counter()
        let (controller, registrar, _) = try makeController(onToggle: toggles.increment)
        controller.apply()

        registrar.press()

        XCTAssertEqual(toggles.count, 1)
    }

    /// Two reasons to go quiet, one switch. While the status menu is open AppKit presses the
    /// menu line itself, and a second toggle from here would undo it. While a new combination
    /// is being recorded, the old one is still registered and would fire on the way in.
    func testAPressDoesNothingWhileTheShortcutIsMuted() throws {
        let toggles = Counter()
        let (controller, registrar, _) = try makeController(onToggle: toggles.increment)
        controller.apply()
        controller.isMuted = true

        registrar.press()

        XCTAssertEqual(toggles.count, 0)
    }

    func testTheMenuPrintsTheCombinationBesideTheLineItPresses() throws {
        let (controller, _, _) = try makeController()
        let item = NSMenuItem()
        controller.apply()

        controller.showShortcut(on: item)

        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .command])
    }

    /// A menu line that prints `⌥⌘W` while another application holds `⌥⌘W` promises something
    /// the app cannot do. The settings window is where the reason belongs; the menu just stops
    /// claiming it.
    func testTheMenuPrintsNothingWhenTheCombinationDoesNotWork() throws {
        let (controller, registrar, _) = try makeController()
        let item = NSMenuItem()
        registrar.answer = .alreadyOurs
        controller.apply()

        controller.showShortcut(on: item)

        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])
    }

    private func optionCommandW() throws -> WidgetShortcut {
        try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))
    }

    private func makeController(onToggle: @escaping () -> Void = {}) throws -> (
        WidgetShortcutController, FakeShortcutRegistrar, WidgetSettingsStore
    ) {
        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        let registrar = FakeShortcutRegistrar()
        let controller = WidgetShortcutController(
            settings: settings,
            registrar: registrar,
            onToggle: onToggle
        )
        return (controller, registrar, settings)
    }
}

@MainActor
private final class Counter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
