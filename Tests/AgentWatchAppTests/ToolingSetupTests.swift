import AgentWatchCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

@MainActor
final class ToolingSetupTests: XCTestCase {
    func testRestartAndNavigationDoNotChangeAnyIntegration() {
        var writes: [ToolingPress] = []
        let tooling = ToolingModel(facts: { self.facts() }, act: { writes.append($0) })
        tooling.pageOpened()
        XCTAssertNil(tooling.journey, "with something connected, the page opens on the overview")

        tooling.startSetup()
        tooling.choose(.claude)
        XCTAssertEqual(tooling.journey?.step, .connect)
        tooling.continueToVerification()
        XCTAssertEqual(tooling.journey?.step, .ready, "an agent heard from already is past waiting")
        tooling.back()
        tooling.startSetup()
        XCTAssertEqual(tooling.journey?.step, .choose)
        tooling.finishSetup()

        XCTAssertNil(tooling.journey)
        XCTAssertTrue(writes.isEmpty)
    }

    func testInstallIsExplicitAndExistingHooksCannotBeRemovedByTheGuide() {
        var reading = facts(hooks: .absent)
        var presses: [ToolingPress] = []
        let tooling = ToolingModel(facts: { reading }, act: { presses.append($0) })
        tooling.pageOpened()
        tooling.choose(.codex)
        XCTAssertFalse(tooling.canContinue)
        tooling.continueToVerification()
        XCTAssertEqual(tooling.journey?.step, .connect, "nothing to try before the hooks are written")
        XCTAssertTrue(presses.isEmpty)

        tooling.connect()
        tooling.connectStatusLine()

        XCTAssertEqual(
            presses,
            [.install(.init(source: .codex, kind: .hooks)), .install(.init(source: .claude, kind: .statusLine))],
            "the guide only ever installs; a remove is a press on the overview")
        reading = facts(hooks: .unheard)
        tooling.reread()
        XCTAssertTrue(tooling.canContinue)
        tooling.continueToVerification()
        XCTAssertEqual(tooling.journey?.step, .verify)
    }

    /// With nothing connected the overview is a column of `Install` buttons, so a visit starts the
    /// guide; a visit to a page somebody has already set up does not.
    func testAVisitStartsTheGuideOnlyWhenNothingIsConnected() {
        let empty = ToolingModel(facts: { self.facts(hooks: .absent) }, act: { _ in })
        empty.pageOpened()
        XCTAssertEqual(empty.journey?.step, .choose)

        let connected = ToolingModel(facts: { self.facts(hooks: .unheard) }, act: { _ in })
        connected.pageOpened()
        XCTAssertNil(connected.journey)
    }

    /// A failure belongs to the press that produced it, so the next visit starts without it.
    func testAVisitForgetsTheLastPressesError() {
        var forgotten = 0
        let tooling = ToolingModel(facts: { self.facts() }, act: { _ in }, forgetLastError: { forgotten += 1 })
        tooling.pageOpened()
        tooling.reread()
        XCTAssertEqual(forgotten, 1, "a reread after a press keeps the error it is about")
    }

    /// The first event moves a waiting guide on without anything pressed; later ones change
    /// nothing on the page and are not worth a look at the disk.
    func testTheFirstEventMovesAWaitingGuideOn() {
        var reading = facts(hooks: .unheard)
        var reads = 0
        let tooling = ToolingModel(
            facts: {
                reads += 1
                return reading
            }, act: { _ in })
        tooling.pageOpened()
        tooling.startSetup()
        tooling.choose(.claude)
        tooling.continueToVerification()
        XCTAssertEqual(tooling.journey?.step, .verify)

        reading = facts()
        tooling.receivedEvents([.claude, .codex])
        XCTAssertEqual(tooling.journey?.step, .ready)
        let readsAfterTheFirst = reads
        tooling.receivedEvents([.claude, .codex])
        XCTAssertEqual(reads, readsAfterTheFirst)
    }

    /// The sender's path is an internal detail until the entries name this very copy of the
    /// app, and then it is the one thing about to break: shown in that case only.
    func testTheSenderIsShownOnlyWhenTheHooksNameThisCopy() throws {
        XCTAssertNil(ToolingReport.senderNote(senderPath: "/Applications/AgentWatch.app", isTiedToThisBuild: false))
        let note = try XCTUnwrap(
            ToolingReport.senderNote(senderPath: "/Applications/AgentWatch.app", isTiedToThisBuild: true))
        XCTAssertEqual(note.details, ["/Applications/AgentWatch.app"])
        XCTAssertTrue(note.nextStep?.contains("moved or deleted") == true, "and says what that costs")
    }

    /// The guide prints the combination only while it works, as the menu does.
    func testTheGuideNamesTheShortcutOnlyWhileItWorks() {
        XCTAssertEqual(
            setupWidgetToggleText(shortcut: "⌃⌥K"),
            "⌃⌥K shows or hides the widget (you can change it in Settings → General)."
        )
        let without = setupWidgetToggleText(shortcut: nil)
        XCTAssertFalse(without.contains("⌥⌘W"), without)
        XCTAssertTrue(without.hasPrefix("Show Widget in the menu bar"), without)
    }

    func testEmptyWidgetOffersAnAccessibleControlThatCannotDragTheWindow() throws {
        var opened = false
        let view = HUDEmptyStateView(
            background: .graphite, backgroundOpacity: 1, complaint: "Not connected", openSetup: { opened = true })
        let control = try button("Connect Agent →", in: view)
        XCTAssertFalse(control.mouseDownCanMoveWindow)
        XCTAssertTrue(control.acceptsFirstMouse(for: nil))
        control.performClick(nil)
        XCTAssertTrue(opened)
    }

    func testRealMouseClickOpensSetupWithoutMovingTheWidget() throws {
        guard ProcessInfo.processInfo.environment["SETUP_CLICK_PROBE"] == "1" else {
            throw XCTSkip("Set SETUP_CLICK_PROBE=1 for the real mouse check")
        }
        XCTAssertTrue(AXIsProcessTrusted(), "Accessibility permission is required for real mouse events")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        var opened = false
        let panel = HUDPanel(
            contentRect: NSRect(x: 180, y: 180, width: 420, height: 64),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        let view = HUDEmptyStateView(
            background: .graphite, backgroundOpacity: 1,
            complaint: "Connect an agent to start watching sessions", openSetup: { opened = true })
        panel.contentView = view
        panel.level = .floating
        panel.hideStandardButtons()
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        defer { panel.close() }
        view.layoutSubtreeIfNeeded()
        let control = try button("Connect Agent →", in: view)
        let frame = panel.frame
        let screenPoint = panel.convertPoint(
            toScreen: control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil))
        let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let point = CGPoint(x: screenPoint.x, y: top - screenPoint.y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            try XCTUnwrap(
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            ).post(tap: .cghidEventTap)
        }
        let deadline = Date().addingTimeInterval(3)
        while !opened && Date() < deadline {
            if let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true)
            {
                NSApplication.shared.sendEvent(event)
            }
        }
        XCTAssertTrue(opened, "A real mouse event must reach the setup control")
        XCTAssertEqual(panel.frame, frame, "Opening setup must not move the widget")
    }

    /// Every step of the guide and the overview, as the settings window shows them; the README
    /// shows the connection step.
    func testRenderSetupForDocumentation() throws {
        guard let directory = ProcessInfo.processInfo.environment["SETUP_RENDER_DIR"] else {
            throw XCTSkip("Set SETUP_RENDER_DIR to render the setup guide")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var reading = facts(hooks: .absent)
        let tooling = ToolingModel(facts: { reading }, act: { _ in })
        let page = ToolingPane(tooling: tooling)
        tooling.pageOpened()
        // Each step as tall as its content, so its buttons sit under it rather than a page away.
        try draw(page, height: 540, name: "setup-choose", directory: directory)
        tooling.choose(.claude)
        try draw(page, height: 540, name: "setup-connect", directory: directory)
        reading = facts(hooks: .unheard)
        tooling.reread()
        tooling.continueToVerification()
        try draw(page, height: 620, name: "setup-try", directory: directory)
        reading = facts()
        tooling.reread()
        try draw(page, height: 620, name: "setup-ready", directory: directory)
        tooling.finishSetup()
        try draw(page, height: 720, name: "setup-overview", directory: directory)
    }

    private func facts(
        hooks: ToolingInstallationState = .installed,
        senderIsTiedToThisBuild: Bool = false
    ) -> ToolingFacts {
        ToolingFacts(
            hookState: { _ in hooks }, statusLineState: .notSet,
            hooksPath: { $0 == .claude ? "~/.claude/skills/agent-watch/hooks/hooks.json" : "~/.codex/hooks.json" },
            statusLinePath: "~/.claude/settings.json", senderPath: "AgentWatchSend",
            senderIsTiedToThisBuild: senderIsTiedToThisBuild,
            idePlugins: [], stagedPlugin: nil, idePluginDirectoryPath: "",
            agentPaths: [.claude: "~/.local/bin/claude", .codex: "/opt/homebrew/bin/codex"],
            receivedSources: hooks == .installed ? [.claude, .codex] : [])
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(buttons(in: view).first { $0.title == title }, "Button: \(title)")
    }

    /// 570 points: the settings window opens 760 wide, and its sidebar takes about 190 of them.
    private func draw(_ page: ToolingPane, height: CGFloat, name: String, directory: String) throws {
        // As `SettingsView` shows a page: the forms on the window's own background, which the
        // buttons under the guide share. Without it they sit on nothing, transparent in the PNG.
        let hosting = NSHostingView(
            rootView: page.formStyle(.grouped).scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 570, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        // SwiftUI fills a form in over a few turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
