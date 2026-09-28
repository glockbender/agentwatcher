import AgentWatchCore
import AgentWatchTestSupport
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
                "  Widget Settings…",
                "  Tooling…",
                "  ---",
                "  Menu Bar Icon",
                "    Sphere",
                "    Counts",
                "    ---",
                "    Needs You",
                "    Working",
                "    Done",
                "    Idle",
                "  Sessions in Menu",
                "    List Sessions in Menu",
                "    ---",
                "    Needs You",
                "    Working",
                "    Done",
                "    Idle",
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
        settings.setMenuBarIconStyle(.counts)
        settings.setMenuBarIconShows(.quiet, false)
        settings.setLocksPosition(true)
        settings.setClosedSessionRetention(.manual)
        settings.setTranscriptPollInterval(nil)
        host.attentionCounts = SessionAttentionCounts(needsPerson: 1, working: 2, done: 0, quiet: 0)
        host.isWidgetVisible = true
        host.isEventDebugVisible = true
        host.checksForUpdatesOnLaunch = false

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(menu.summaryItem?.title, "1 needs you · 2 working")
        XCTAssertEqual(MenuBarIconStyle.allCases.filter { menu.iconStyleRows[$0]?.isOn == true }, [.counts])
        XCTAssertEqual(
            SessionAttention.counted.filter { menu.iconAttentionRows[$0]?.isOn == true },
            [.needsPerson, .working, .done]
        )
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
            ("Widget Settings…", "showWidgetSettings"),
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

    // MARK: - Sessions in the menu

    /// Directly under the summary, so the line that counts the sessions heads the list of them.
    func testListedSessionsAreTheFirstLinesUnderTheSummary() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [
            session(0, "Waiting on a question", .waitingForUser),
            session(1, "Still building", .executing),
            session(2, "Finished the port", .completed),
        ]

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(
            Array(outline(menu.menu).prefix(5)),
            ["No active sessions", "Waiting on a question", "Finished the port", "---", "Show Widget"],
            "the defaults list the sessions that need a person or are done, and no others"
        )
        XCTAssertEqual(
            menu.sessionLineItems.map { $0.image?.accessibilityDescription },
            ["Needs You", "Done"],
            "every line carries its state's mark, and the mark says its state out loud"
        )
    }

    func testChoosingALineIsAClickOnThatSessionsRow() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [session(0, "Waiting on a question", .waitingForUser)]
        menu.menuWillOpen(menu.menu)
        host.calls = []

        try choose(XCTUnwrap(menu.sessionLineItems.first))

        XCTAssertEqual(host.calls, ["focusSession claude:session-0"])
        XCTAssertEqual(host.announcedReleases, [false])
    }

    func testChoosingALinePreservesTheActionThatWasDisplayed() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [session(0, "Session", .completed)]
        menu.menuWillOpen(menu.menu)
        let ordinary = try XCTUnwrap(menu.sessionLineItems.first)

        host.sessions = [session(0, "Session", .terminalClosed)]
        host.reaches = ["claude:session-0": .closedTerminal(devicePath: "/dev/ttys004")]
        try choose(ordinary)
        XCTAssertEqual(host.announcedReleases, [false], "the old title announced no terminal release")

        menu.menuWillOpen(menu.menu)
        let announced = try XCTUnwrap(menu.sessionLineItems.first)
        XCTAssertTrue(announced.title.contains("click ends the agent"))
        try choose(announced)
        XCTAssertEqual(host.announcedReleases, [false, true])
    }

    func testOpeningTheMenuAgainListsTheSessionsAsTheyAreNow() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [session(0, "First", .waitingForUser), session(1, "Second", .completed)]
        menu.menuWillOpen(menu.menu)

        host.sessions = [session(1, "Second", .completed)]
        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(menu.sessionLineItems.map(\.title), ["Second"])
        XCTAssertEqual(outline(menu.menu).filter { $0 == "Second" }.count, 1, "a line was left behind")
    }

    /// Off keeps the chosen states, and the menu goes back to the summary alone.
    func testTurningTheListOffTakesItsLinesAway() throws {
        let (menu, host, settings) = try makeMenu()
        host.sessions = [session(0, "Waiting on a question", .waitingForUser)]
        menu.menuWillOpen(menu.menu)

        settings.setListsSessionsInMenu(false)
        menu.refresh()

        XCTAssertEqual(menu.sessionLineItems, [])
        XCTAssertEqual(Array(outline(menu.menu).prefix(2)), ["No active sessions", "---"])
    }

    /// A menu enables its own lines as it opens, so a line is greyed by having nothing to do.
    func testALineWhoseClickCouldDoNothingIsGreyed() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [session(0, "Left behind", .terminalClosed)]
        host.reaches = ["claude:session-0": .closedTerminal(devicePath: nil)]

        menu.menuWillOpen(menu.menu)

        let line = try XCTUnwrap(menu.sessionLineItems.first)
        XCTAssertEqual(line.title, "Left behind — terminal closed, nothing here can end it")
        XCTAssertNil(line.action)
    }

    /// The mark is what tells the states apart, so it has to be drawn: a palette given one
    /// colour paints the mark the colour of its disc, and all four lines showed a plain dot.
    func testEveryLinesMarkIsDrawnInsideItsDisc() throws {
        for attention in SessionAttention.counted {
            let image = try XCTUnwrap(StatusMenu.mark(for: attention), "\(attention) has no mark")
            let inked = try inkedPixels(of: image)

            let white = inked.filter { $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 }
            // Measured at 4x: the thinnest marks, `!` and `−`, are 4.1 % and 4.8 % of the ink,
            // and a mark painted the colour of its disc is exactly 0 %.
            XCTAssertGreaterThan(
                Double(white.count) / Double(inked.count), 0.02,
                "\(attention.name): no mark inside the disc"
            )
            XCTAssertLessThan(
                Double(white.count) / Double(inked.count), 0.6, "\(attention.name): no disc around the mark")
        }
    }

    /// Every pixel of an image drawn at four times its size that is more ink than not.
    private func inkedPixels(of image: NSImage) throws -> [NSColor] {
        let scale = 4
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width) * scale,
                pixelsHigh: Int(image.size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked: [NSColor] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.9 {
                    inked.append(color)
                }
            }
        }
        return inked
    }

    // MARK: - Choosing which sessions

    func testTheChoiceOffersEveryCountedStateAndShowsWhatIsStored() throws {
        let (menu, _, _) = try makeMenu()

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(menu.listSessionsRow?.isOn, true)
        XCTAssertEqual(Set(menu.attentionRows.keys), Set(SessionAttention.counted))
        XCTAssertEqual(
            SessionAttention.counted.filter { menu.attentionRows[$0]?.isOn == true },
            [.needsPerson, .done]
        )
        XCTAssertEqual(
            menu.attentionRows[.working]?.accessibilityRole(),
            .checkBox,
            "a line that draws itself says what it is to a screen reader"
        )
    }

    /// The styles are one choice: picking one writes it and moves the tick, and a screen
    /// reader hears a group of radio buttons rather than two checkboxes.
    func testTheIconStylesAreOneChoice() throws {
        let (menu, _, settings) = try makeMenu()
        menu.menuWillOpen(menu.menu)
        XCTAssertEqual(MenuBarIconStyle.allCases.filter { menu.iconStyleRows[$0]?.isOn == true }, [.sphere])

        try XCTUnwrap(menu.iconStyleRows[.counts]).toggle()

        XCTAssertEqual(settings.menuBarIconStyle, .counts)
        XCTAssertEqual(MenuBarIconStyle.allCases.filter { menu.iconStyleRows[$0]?.isOn == true }, [.counts])
        XCTAssertEqual(menu.iconStyleRows[.counts]?.accessibilityRole(), .radioButton)
        XCTAssertEqual(menu.iconAttentionRows[.working]?.accessibilityRole(), .checkBox)
    }

    /// An icon with nothing to count has nothing to draw, so the last state left is greyed
    /// and says why on its own line — and a click on it changes nothing.
    func testTheLastStateInTheIconCannotBeTakenAway() throws {
        let (menu, _, settings) = try makeMenu()
        menu.menuWillOpen(menu.menu)

        for attention in [SessionAttention.working, .done, .quiet] {
            try XCTUnwrap(menu.iconAttentionRows[attention]).toggle()
        }

        let last = try XCTUnwrap(menu.iconAttentionRows[.needsPerson])
        XCTAssertEqual(settings.menuBarIconAttentions, [.needsPerson])
        XCTAssertFalse(last.isAvailable)
        XCTAssertEqual(last.note, StatusMenu.lastIconStateNote)
        XCTAssertEqual(
            SessionAttention.counted.filter { menu.iconAttentionRows[$0]?.note != nil },
            [.needsPerson],
            "a line that can still be chosen carries the reason it cannot"
        )
        last.toggle()
        XCTAssertEqual(settings.menuBarIconAttentions, [.needsPerson])

        try XCTUnwrap(menu.iconAttentionRows[.done]).toggle()
        XCTAssertTrue(last.isAvailable, "a second state did not free the first")
        XCTAssertNil(last.note)
    }

    /// The note appears while the menu is open, so its room is taken when the line is made:
    /// whether an open menu widens for a line that grows has not been measured.
    func testTheLastStatesNoteFitsTheLineItIsOn() throws {
        let (menu, _, settings) = try makeMenu()
        menu.menuWillOpen(menu.menu)
        let row = try XCTUnwrap(menu.iconAttentionRows[.needsPerson])
        let text = "\(row.title) — \(StatusMenu.lastIconStateNote)" as NSString
        let needed = text.size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        let mark = try XCTUnwrap(row.image).size.width

        for attention in [SessionAttention.working, .done, .quiet] {
            settings.setMenuBarIconShows(attention, false)
        }
        menu.refreshMenuBarIcon()

        XCTAssertNotNil(row.note)
        XCTAssertGreaterThanOrEqual(row.frame.width, 23 + mark + 6 + needed, "the note runs past the line")
    }

    /// The counts can move while the menu is open. The first line follows them; the session
    /// lines keep their wording until the menu opens again, so none moves under the pointer.
    func testTheFirstLineFollowsTheCountsWhileTheMenuIsOpen() throws {
        let (menu, host, settings) = try makeMenu()
        settings.setMenuLists(.working, true)
        host.sessions = [session(0, "Still building", .executing)]
        host.attentionCounts = SessionAttentionCounts(needsPerson: 0, working: 1, done: 0, quiet: 0)
        menu.menuWillOpen(menu.menu)
        let linesBefore = menu.sessionLineItems

        host.sessions = [session(0, "Still building", .waitingForUser)]
        host.attentionCounts = SessionAttentionCounts(needsPerson: 1, working: 0, done: 0, quiet: 0)
        menu.refreshSummary()

        XCTAssertEqual(menu.summaryItem?.title, "1 needs you")
        XCTAssertEqual(menu.sessionLineItems, linesBefore)
    }

    /// The menu is still open when a state is chosen, and the lines at its top follow at once.
    func testChoosingAStateListsItsSessionsWithoutReopeningTheMenu() throws {
        let (menu, host, settings) = try makeMenu()
        host.sessions = [session(0, "Still building", .executing)]
        menu.menuWillOpen(menu.menu)
        XCTAssertEqual(menu.sessionLineItems, [], "working is not listed by default")

        try XCTUnwrap(menu.attentionRows[.working]).toggle()

        XCTAssertTrue(settings.menuSessionAttentions.contains(.working))
        XCTAssertEqual(menu.attentionRows[.working]?.isOn, true)
        XCTAssertEqual(menu.sessionLineItems.map(\.title), ["Still building"])
    }

    /// Off greys the states rather than hiding them, keeps what they were, and takes the lines
    /// away at once.
    func testTheSwitchGreysTheStatesAndKeepsThem() throws {
        let (menu, host, settings) = try makeMenu()
        host.sessions = [session(0, "Waiting on a question", .waitingForUser)]
        menu.menuWillOpen(menu.menu)

        try XCTUnwrap(menu.listSessionsRow).toggle()

        XCTAssertFalse(settings.listsSessionsInMenu)
        XCTAssertEqual(menu.sessionLineItems, [])
        XCTAssertEqual(menu.attentionRows.values.map(\.isAvailable), [false, false, false, false])
        XCTAssertEqual(menu.attentionRows[.needsPerson]?.isOn, true, "the choice is kept for later")

        try XCTUnwrap(menu.attentionRows[.quiet]).toggle()
        XCTAssertFalse(settings.menuSessionAttentions.contains(.quiet), "a greyed line took a click")
    }

    /// The menu hands its keys to the highlighted line: Return and Space choose it, and every
    /// other key goes on to the menu. Measured on macOS 15.3.1 — and the item's own action is
    /// never called for a line with a view, so it is not where the keyboard is handled.
    func testReturnAndSpaceChooseALineAndOtherKeysGoOnToTheMenu() throws {
        let (menu, _, settings) = try makeMenu()
        menu.menuWillOpen(menu.menu)
        let idle = try XCTUnwrap(menu.attentionRows[.quiet])
        XCTAssertTrue(idle.acceptsFirstResponder, "without it the menu keeps its keys to itself")

        idle.keyDown(with: try key(36))
        XCTAssertTrue(settings.menuSessionAttentions.contains(.quiet), "Return did not choose the line")
        idle.keyDown(with: try key(49))
        XCTAssertFalse(settings.menuSessionAttentions.contains(.quiet), "Space did not choose the line")
        XCTAssertEqual(idle.accessibilityValue() as? Bool, false)

        let responder = KeyRecorder()
        idle.nextResponder = responder
        idle.keyDown(with: try key(125))
        XCTAssertEqual(responder.keyCodes, [125], "the arrow did not reach the menu")
        XCTAssertFalse(settings.menuSessionAttentions.contains(.quiet), "an arrow chose the line")
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: code
            ))
    }

    private func session(_ index: Int, _ title: String, _ phase: SessionPhase) -> SessionSnapshot {
        testSession(index: index, title: title, phase: phase, lastObservedAt: Date(timeIntervalSince1970: 1_000))
    }

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

/// Stands where the menu stands behind a line, and writes down the keys passed on to it.
final class KeyRecorder: NSResponder {
    var keyCodes: [UInt16] = []

    override func keyDown(with event: NSEvent) {
        keyCodes.append(event.keyCode)
    }
}

@MainActor
final class FakeStatusMenuHost: StatusMenuHost {
    var calls: [String] = []
    var announcedReleases: [Bool] = []
    var attentionCounts = SessionAttentionCounts.empty
    var isWidgetVisible = false
    var isEventDebugVisible = false
    var checksForUpdatesOnLaunch = true
    var isReadingTranscripts = false
    var transcriptFaultedSessionCount = 0
    var sessions: [SessionSnapshot] = []
    var reaches: [String: SessionReach] = [:]

    func reach(for snapshot: SessionSnapshot) -> SessionReach {
        reaches[snapshot.id] ?? .anApplication
    }

    func focusSession(id: String, endingAgentWasAnnounced: Bool) {
        calls.append("focusSession \(id)")
        announcedReleases.append(endingAgentWasAnnounced)
    }

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
