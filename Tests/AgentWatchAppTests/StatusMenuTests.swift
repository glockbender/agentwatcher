import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The status item's menu, read the way a person reads it: its lines, their checkmarks, and
/// what each one does when chosen.
@MainActor
final class StatusMenuTests: XCTestCase {
    /// What a person does while working, then the windows; every setting lives in them.
    func testTheMenuHoldsActionsAndWindowsOnly() throws {
        let (menu, _, _) = try makeMenu()

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(
            outline(menu.menu),
            [
                "No active sessions",
                "Show Widget",
                "---",
                "Settings…",
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

    func testOpeningTheMenuShowsWhatIsGoingOn() throws {
        let (menu, host, _) = try makeMenu()
        host.attentionCounts = SessionAttentionCounts(needsPerson: 1, working: 2, done: 0, quiet: 0)
        host.isWidgetVisible = true
        host.isEventDebugVisible = true

        menu.menuWillOpen(menu.menu)

        XCTAssertEqual(menu.summaryItem?.title, "1 needs you · 2 working")
        XCTAssertEqual(menu.widgetItem?.isHidden, true, "a visible widget needs no line to bring it back")
    }

    func testEachActionLineReachesTheHost() throws {
        let (menu, host, _) = try makeMenu()
        let expected: [(title: String, call: String)] = [
            ("Show Widget", "toggleWidget"),
            ("Settings…", "showWidgetSettings"),
            ("Quit Agent Watch", "quit"),
        ]

        for (title, call) in expected {
            host.calls = []
            try choose(XCTUnwrap(item(titled: title, in: menu.menu), "no line \(title)"))
            XCTAssertEqual(host.calls, [call], title)
        }
    }

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
            ["No active sessions", "Waiting on a question", "Finished the port", "Show Widget", "---"],
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
    }

    // MARK: - The question in the menu

    /// A broken session's line draws itself, so its click reaches it with the menu still open,
    /// and it keeps an action, so the menu does not read it as disabled and never light it up.
    func testABrokenSessionsLineDrawsItselfAndStaysEnabled() throws {
        let (menu, _, _) = try openMenuWithABrokenSession()

        let line = try XCTUnwrap(menu.sessionLineItems.first)
        let view = try XCTUnwrap(line.view as? MenuBrokenSessionLineView)
        XCTAssertTrue(view.title.hasSuffix("end its agent…"), view.title)
        XCTAssertNotNil(line.action)
        XCTAssertNotNil(view.image, "it carries its state's mark, like the other lines")
    }

    /// The menu cannot draw over its lines, so they give way: the question stands where they
    /// were, and the rest of the menu stays around it.
    func testChoosingTheLinePutsTheQuestionWhereTheLinesWere() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()

        try brokenLine(in: menu).choose()

        XCTAssertEqual(host.calls.last, "focusSession claude:session-0")
        XCTAssertEqual(menu.askingAbout, "claude:session-0")
        XCTAssertEqual(menu.sessionLineItems.count, 1)
        let question = try XCTUnwrap(menu.sessionLineItems.first?.view as? MenuEndAgentQuestionView)
        XCTAssertEqual(question.dialog.sessionID, "claude:session-0")
        XCTAssertEqual(
            question.frame.height, question.dialog.heightShowingEverything(atWidth: MenuEndAgentQuestionView.width))
        question.layoutSubtreeIfNeeded()
        XCTAssertFalse(question.dialog.isCompact, "a menu line is as tall as the whole question needs")
        XCTAssertEqual(Array(outline(menu.menu).prefix(3)), ["No active sessions", "Broken session", "Show Widget"])
    }

    func testCancelBringsTheLinesBack() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        try brokenLine(in: menu).choose()

        try question(in: menu).dialog.cancelButton.performClick(nil)

        XCTAssertNil(menu.askingAbout)
        XCTAssertNotNil(menu.sessionLineItems.first?.view as? MenuBrokenSessionLineView)
        XCTAssertEqual(host.ended, [])
    }

    func testEndEndsTheAgentOfThatSession() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        try brokenLine(in: menu).choose()

        try question(in: menu).dialog.endButton.performClick(nil)

        XCTAssertEqual(host.ended, ["claude:session-0"])
        XCTAssertNil(menu.askingAbout)
    }

    /// Closing the menu with the question open — Escape, a click elsewhere — is a no, and the
    /// next opening shows the lines.
    func testClosingTheMenuIsANo() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        try brokenLine(in: menu).choose()

        menu.menuDidClose(menu.menu)
        menu.menuWillOpen(menu.menu)

        XCTAssertNil(menu.askingAbout)
        XCTAssertNotNil(menu.sessionLineItems.first?.view as? MenuBrokenSessionLineView)
        XCTAssertEqual(host.ended, [])
    }

    /// Asked again on every rebuild: a session that came back to its terminal is no longer
    /// the question.
    func testAQuestionAboutASessionNoLongerBrokenIsDropped() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        try brokenLine(in: menu).choose()

        host.sessions = [session(0, "Session", .waitingForUser)]
        menu.refreshSessions()

        XCTAssertNil(menu.askingAbout)
        XCTAssertEqual(menu.sessionLineItems.map(\.title), ["Session"])
    }

    /// A line whose click asks nothing — the ending is no longer there by the time of the
    /// click — leaves the lines as they are.
    func testALineWhoseClickNoLongerAsksLeavesTheLines() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        host.clicks = [:]

        try brokenLine(in: menu).choose()

        XCTAssertNil(menu.askingAbout)
        XCTAssertNotNil(menu.sessionLineItems.first?.view as? MenuBrokenSessionLineView)
    }

    /// The release lands on the question's own view, which hands it to the button under it.
    /// Called here rather than clicked: what a real menu delivers is for a real click to show.
    func testAReleaseOverEndIsAnEnd() throws {
        let (menu, host, _) = try openMenuWithABrokenSession()
        try brokenLine(in: menu).choose()
        let question = try question(in: menu)
        let window = NSWindow(
            contentRect: question.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = question
        question.layoutSubtreeIfNeeded()
        let end = question.dialog.endButton
        let point = end.convert(NSPoint(x: end.bounds.midX, y: end.bounds.midY), to: nil)

        XCTAssertTrue(question.hitTest(question.convert(point, from: nil)) === question, "the buttons take no press")
        let release = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        question.mouseUp(with: release)

        XCTAssertEqual(host.ended, ["claude:session-0"])
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
        XCTAssertEqual(Array(outline(menu.menu).prefix(2)), ["No active sessions", "Show Widget"])
    }

    /// A menu enables its own lines as it opens, so a line is greyed by having nothing to do.
    func testALineWhoseClickCouldDoNothingIsGreyed() throws {
        let (menu, host, _) = try makeMenu()
        host.sessions = [session(0, "Left behind", .terminalClosed)]
        host.reaches = ["claude:session-0": .closedTerminal(nil)]

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

    private func session(_ index: Int, _ title: String, _ phase: SessionPhase) -> SessionSnapshot {
        testSession(index: index, title: title, phase: phase, lastObservedAt: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - Helpers

    private func openMenuWithABrokenSession() throws -> (StatusMenu, FakeStatusMenuHost, WidgetSettingsStore) {
        let (menu, host, settings) = try makeMenu()
        let ending = ClosedTerminalEnding.discardOutput(devicePath: "/dev/ttys004")
        host.sessions = [session(0, "Session", .terminalClosed)]
        host.reaches = ["claude:session-0": .closedTerminal(ending)]
        host.clicks = ["claude:session-0": .asksToEndAgent(ending)]
        menu.menuWillOpen(menu.menu)
        return (menu, host, settings)
    }

    private func brokenLine(in menu: StatusMenu) throws -> MenuBrokenSessionLineView {
        try XCTUnwrap(menu.sessionLineItems.first?.view as? MenuBrokenSessionLineView)
    }

    private func question(in menu: StatusMenu) throws -> MenuEndAgentQuestionView {
        try XCTUnwrap(menu.sessionLineItems.first?.view as? MenuEndAgentQuestionView)
    }

    private func makeMenu() throws -> (StatusMenu, FakeStatusMenuHost, WidgetSettingsStore) {
        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        let host = FakeStatusMenuHost()
        let menu = StatusMenu(settings: settings, host: host)
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
final class FakeStatusMenuHost: StatusMenuHost, SettingsHost {
    var calls: [String] = []
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

    /// What each session's click comes to; a window comes forward for any other.
    var clicks: [String: SessionClick] = [:]
    var ended: [String] = []

    func focusSession(id: String) -> SessionClick {
        calls.append("focusSession \(id)")
        return clicks[id] ?? .raised
    }

    func endAgent(ofSessionWithID id: String) {
        calls.append("endAgent \(id)")
        ended.append(id)
    }

    func menuWillOpen() { calls.append("menuWillOpen") }
    func showShortcut(on item: NSMenuItem) { calls.append("showShortcut") }
    func toggleWidget() { calls.append("toggleWidget") }
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
