import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The settings window as a whole: what it holds while closed, and what leaving a page ends.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// Closed, the window holds no pages; opened again, it builds them, on the page it was on.
    func testTheSettingsWindowLetsGoOfItsPagesWhenItCloses() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        let controller = SettingsWindowController(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        controller.buildPages()
        controller.model.go(.theme)
        XCTAssertTrue(controller.hasPages)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        let started = Date()
        nextTurn()
        let waited = Date().timeIntervalSince(started)
        let visible = controller.window?.isVisible
        let content = controller.window?.contentView.map { String(describing: type(of: $0)) }
        let heldAtOnce = controller.hasPages
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        XCTAssertFalse(
            heldAtOnce,
            "waited \(waited) s, visible \(String(describing: visible)), content \(String(describing: content)), "
                + "still held a second later: \(controller.hasPages)")
        controller.buildPages()
        XCTAssertTrue(controller.hasPages)
        XCTAssertEqual(controller.model.page, .theme)
    }

    /// The button may go with its page before anything tells it to stop; the combination it
    /// muted is heard again all the same.
    func testARecordingWhoseButtonWentLeavesNothingMuted() throws {
        let (model, shortcuts) = try makeModel()
        model.go(.general)
        do {
            let recorder = ShortcutRecorderButton()
            model.shortcutRecorder = recorder
            model.startRecordingShortcut()
        }
        XCTAssertNil(model.shortcutRecorder)
        XCTAssertTrue(shortcuts.isMuted)

        model.go(.widget)

        XCTAssertFalse(shortcuts.isMuted)
    }

    private func makeModel() throws -> (SettingsModel, WidgetShortcutController) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        let shortcuts = FakeShortcutRegistrar.controller(for: settings)
        let model = SettingsModel(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences), shortcuts: shortcuts, host: host, version: nil)
        return (model, shortcuts)
    }

    private func nextTurn() {
        let done = expectation(description: "the main queue has run what it held")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
