import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The menu's list of sessions in a real menu, for a person to look at and touch.
///
/// Tests and offscreen drawings cannot show what the list does inside a real menu: the menu's
/// material behind a greyed line, the trackpad's and the wheel's scroll, the hover after a
/// scroll, the arrows stepping over the list. Run it after a macOS update to re-check those
/// rows of `docs/measurements.md`:
///
///     MENU_LIST_PROBE=1 swift test --filter MenuListProbe
///
/// A `⇅ probe` item appears in the menu bar with the app's own menu over twelve invented
/// sessions: eight shown, one greyed, one broken. Nothing chosen in it does anything real, and
/// your own Agent Watch can stay open. Choose `Quit Agent Watch` in it to end; it gives up by
/// itself after ten minutes. Skipped without the variable, since it waits for a person.
@MainActor
final class MenuListProbe: XCTestCase {
    func testShowTheListInARealMenu() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MENU_LIST_PROBE"] != nil, "waits for a person")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        let host = FakeAppHost()
        let ending = AgentEnding.discardOutput(devicePath: "/dev/ttys004")
        let observed = Date(timeIntervalSince1970: 1_000)
        host.sessions = (0..<12).map { index in
            switch index {
            case 2: testSession(index: index, title: "Left behind", phase: .terminalClosed, lastObservedAt: observed)
            case 5: testSession(index: index, title: "Broken", phase: .terminalClosed, lastObservedAt: observed)
            default:
                testSession(
                    index: index, title: "Session \(index + 1)", phase: index % 2 == 0 ? .waitingForUser : .completed,
                    lastObservedAt: observed)
            }
        }
        host.reaches = ["claude:session-2": .closedTerminal(nil), "claude:session-5": .closedTerminal(ending)]
        host.clicks = ["claude:session-5": .asksToEndAgent(ending)]
        let menu = StatusMenu(settings: settings, host: host)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⇅ probe"
        item.menu = menu.menu
        defer { NSStatusBar.system.removeStatusItem(item) }

        print("MENU_LIST_PROBE: click ⇅ probe in the menu bar; choose Quit Agent Watch in it to end")
        let deadline = Date().addingTimeInterval(600)
        while !host.calls.contains("quit"), Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
        }
        print("MENU_LIST_PROBE: the host was asked \(host.calls)")
    }
}
