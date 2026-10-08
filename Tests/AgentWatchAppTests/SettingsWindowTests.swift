import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The settings window as a whole: what it holds while closed, and what leaving a page ends.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// The order the owner chose; Diagnostics, which they did not place, stays last.
    func testTheSidebarListsThePagesInTheChosenOrder() {
        XCTAssertEqual(
            SettingsPage.sidebar.map(\.title),
            ["General", "Tooling", "Appearance", "Menu Bar", "Widget", "Diagnostics"]
        )
    }

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
        nextTurn()

        XCTAssertFalse(controller.hasPages)
        controller.buildPages()
        XCTAssertTrue(controller.hasPages)
        XCTAssertEqual(controller.model.page, .theme)
    }

    /// The settings window lets go of its pages when it closes; a guide followed beside a
    /// terminal is still on its step when the window opens again.
    func testTheGuideOutlivesTheClosedWindow() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        host.toolingReading = ToolingFacts(
            hookState: { _ in .absent }, statusLineState: .notSet, hooksPath: { _ in "" }, statusLinePath: "",
            senderPath: "", senderIsTiedToThisBuild: false, idePlugins: [], stagedPlugin: nil,
            idePluginDirectoryPath: "")
        addTeardownBlock { _ = host }
        let controller = SettingsWindowController(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        controller.buildPages()
        controller.model.go(.tooling)
        controller.model.tooling.pageOpened()
        controller.model.tooling.choose(.claude)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        nextTurn()
        XCTAssertFalse(controller.hasPages)
        controller.buildPages()

        XCTAssertEqual(controller.model.tooling.journey?.step, .connect)
        XCTAssertEqual(controller.model.tooling.journey?.source, .claude)
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

    /// Ten seconds: two ran out once on the CI machine for macOS 26 and passed on the next run,
    /// so the timeout is only a bound on a hang.
    private func nextTurn() {
        let done = expectation(description: "the main queue has run what it held")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }
}
