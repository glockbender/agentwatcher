import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The status item's menu, read the way a person reads it: its lines, their checkmarks, and
/// what each one does when chosen.
@MainActor
final class StatusMenuTests: XCTestCase {
    /// What a person does while working at the top; every setting, and every window that
    /// holds settings, one level down.
    func testTheMenuPutsActionsFirstAndEverySettingUnderSettings() throws {
        let (menu, _, _) = try makeMenu()

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(
            outline(menu.menu),
            [
                "No active sessions",
                "---",
                "Show Widget",
                "Highlight Widget",
                "---",
                "Settings",
                "  Widget Appearance…",
                "  Tooling…",
                "  ---",
                "  Show Counts in Menu Bar",
                "  Widget Behavior",
                "    Lock Position",
                "    Lock Size",
                "    ---",
                "    Reset Widget Position",
                "    Reset Widget Size",
                "  Closed Sessions",
                "    Remove after 2 minutes",
                "    Remove after 10 minutes",
                "    Keep until dismissed",
                "  Read Session Transcripts",
                "    Nothing to read — no session is working",
                "    ---",
                "    At most every 3 seconds",
                "    At most every 5 seconds",
                "    At most every 10 seconds",
                "    Off",
                "  Updates",
                "    Agent Watch (development build)",
                "    ---",
                "    Check for Updates…",
                "    Check on Launch",
                "  ---",
                "  Show Event Debug",
                "  Record Raw Hook Payloads for 30 Minutes",
                "---",
                "Quit Agent Watch",
            ]
        )
    }

    /// The host first, so that what the lines then read is what it just found.
    func testOpeningTheMenuAsksTheHostBeforeReadingAnything() throws {
        let (menu, host, _) = try makeMenu()

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(host.calls.prefix(2), ["menuWillOpen", "showShortcut"])
    }

    func testOpeningTheMenuShowsWhatIsStoredAndWhatIsGoingOn() throws {
        let (menu, host, settings) = try makeMenu()
        settings.setShowsMenuBarCounts(false)
        settings.setLocksPosition(true)
        settings.setClosedSessionRetention(.manual)
        settings.setTranscriptPollInterval(nil)
        host.attentionCounts = SessionAttentionCounts(needsPerson: 1, working: 2, done: 0, quiet: 0)
        host.isWidgetVisible = true
        host.isEventDebugVisible = true
        host.checksForUpdatesOnLaunch = false

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(menu.summaryItem?.title, "1 needs you · 2 working")
        XCTAssertEqual(menu.countsItem?.state, .off)
        XCTAssertEqual(menu.widgetItem?.title, "Hide Widget")
        XCTAssertEqual(menu.debugItem?.title, "Hide Event Debug")
        XCTAssertEqual(menu.lockPositionItem?.state, .on)
        XCTAssertEqual(menu.lockSizeItem?.state, .off)
        XCTAssertEqual(menu.updateOnLaunchItem?.state, .off)
        XCTAssertEqual(checked(menu.closedSessionItems), ["Keep until dismissed"])
        XCTAssertEqual(checked(menu.transcriptItems), ["Off"])
        XCTAssertEqual(
            menu.transcriptSummaryItem?.title,
            "Not reading — a finished call stays until the turn ends"
        )
    }

    func testEachSettingLineWritesItsSetting() throws {
        let (menu, host, settings) = try makeMenu()
        menu.menuWillOpen(menu.menu)

        try choose(XCTUnwrap(menu.countsItem))
        XCTAssertFalse(settings.showsMenuBarCounts)
        try choose(XCTUnwrap(menu.lockPositionItem))
        XCTAssertTrue(settings.locksPosition)
        try choose(XCTUnwrap(menu.lockSizeItem))
        XCTAssertTrue(settings.locksSize)
        try choose(XCTUnwrap(menu.closedSessionItems.last))
        XCTAssertEqual(settings.closedSessionRetention, .manual)
        try choose(XCTUnwrap(menu.transcriptItems.first))
        XCTAssertEqual(settings.transcriptPollInterval, 3)
        try choose(XCTUnwrap(menu.transcriptItems.last))
        XCTAssertNil(settings.transcriptPollInterval, "the last choice is off")
        try choose(XCTUnwrap(menu.updateOnLaunchItem))
        XCTAssertFalse(host.checksForUpdatesOnLaunch)
    }

    func testEachActionLineReachesTheHost() throws {
        let (menu, host, _) = try makeMenu()
        let expected: [(title: String, call: String)] = [
            ("Show Widget", "toggleWidget"),
            ("Highlight Widget", "highlightWidget"),
            ("Widget Appearance…", "showWidgetSettings"),
            ("Reset Widget Position", "resetWidgetPosition"),
            ("Reset Widget Size", "resetWidgetSize"),
            ("Show Event Debug", "toggleEventDebug"),
            ("Tooling…", "showTooling"),
            ("Check for Updates…", "checkForUpdates"),
            ("Record Raw Hook Payloads for 30 Minutes", "toggleRawHookCapture"),
            ("Quit Agent Watch", "quit"),
        ]

        for (title, call) in expected {
            host.calls = []
            try choose(XCTUnwrap(item(titled: title, in: menu.menu), "no line \(title)"))
            XCTAssertEqual(host.calls, [call], title)
        }
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        func testARunningRecordingSaysWhenItStopsAndWhatItHolds() throws {
            let (menu, host, _) = try makeMenu()
            host.rawCaptureExpiry = Date().addingTimeInterval(9 * 60 + 30)
            host.recordedPayloadBytes = 0

            menu.menuWillOpen(menu.menu)
            XCTAssertEqual(menu.rawCaptureItem?.title, "Stop Recording Raw Hook Payloads (10m)")
            XCTAssertEqual(menu.rawCaptureItem?.state, .on)
            XCTAssertEqual(menu.deleteRecordingsItem?.isHidden, true, "nothing on disk, nothing to delete")

            host.rawCaptureExpiry = nil
            host.recordedPayloadBytes = 2_048
            menu.menuWillOpen(menu.menu)
            XCTAssertEqual(menu.rawCaptureItem?.title, "Record Raw Hook Payloads for 30 Minutes")
            XCTAssertEqual(menu.deleteRecordingsItem?.isHidden, false)
            XCTAssertEqual(
                menu.deleteRecordingsItem?.title,
                "Delete Recorded Payloads (\(ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)))"
            )
        }
    #endif

    // MARK: - Helpers

    private func makeMenu() throws -> (StatusMenu, FakeStatusMenuHost, WidgetSettingsStore) {
        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        let host = FakeStatusMenuHost()
        let menu = StatusMenu(settings: settings, version: nil, host: host)
        // The menu holds its host weakly, as it holds the application, so something has to
        // keep this one alive for the test that does not keep it itself.
        addTeardownBlock { _ = host }
        return (menu, host, settings)
    }

    /// Every line, submenus indented under the line that opens them, `---` for a separator.
    /// Hidden lines are left out, as a person never sees them.
    private func outline(_ menu: NSMenu, depth: Int = 0) -> [String] {
        menu.items.filter { !$0.isHidden }.flatMap { item -> [String] in
            let indent = String(repeating: "  ", count: depth)
            let line = indent + (item.isSeparatorItem ? "---" : item.title)
            return [line] + (item.submenu.map { outline($0, depth: depth + 1) } ?? [])
        }
    }

    private func item(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let found = item.submenu.flatMap({ self.item(titled: title, in: $0) }) {
                return found
            }
        }
        return nil
    }

    private func checked(_ items: [NSMenuItem]) -> [String] {
        items.filter { $0.state == .on }.map(\.title)
    }

    /// What choosing a line does: its action, sent to its target, from the line itself.
    private func choose(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action, "\(item.title) does nothing")
        _ = (item.target as AnyObject).perform(action, with: item)
    }
}

@MainActor
final class FakeStatusMenuHost: StatusMenuHost {
    var calls: [String] = []
    var attentionCounts = SessionAttentionCounts.empty
    var isWidgetVisible = false
    var isEventDebugVisible = false
    var checksForUpdatesOnLaunch = true
    var isReadingTranscripts = false
    var transcriptFaultedSessionCount = 0

    func menuWillOpen() { calls.append("menuWillOpen") }
    func showShortcut(on item: NSMenuItem) { calls.append("showShortcut") }
    func toggleWidget() { calls.append("toggleWidget") }
    func highlightWidget() { calls.append("highlightWidget") }
    func showWidgetSettings() { calls.append("showWidgetSettings") }
    func showTooling() { calls.append("showTooling") }
    func toggleEventDebug() { calls.append("toggleEventDebug") }
    func checkForUpdates() { calls.append("checkForUpdates") }
    func resetWidgetPosition() { calls.append("resetWidgetPosition") }
    func resetWidgetSize() { calls.append("resetWidgetSize") }
    func quit() { calls.append("quit") }

    #if AGENT_WATCH_DEBUG_CAPTURE
        var rawCaptureExpiry: Date?
        var recordedPayloadBytes = 0
        func toggleRawHookCapture() { calls.append("toggleRawHookCapture") }
        func deleteRawHookRecordings() { calls.append("deleteRawHookRecordings") }
    #endif
}
