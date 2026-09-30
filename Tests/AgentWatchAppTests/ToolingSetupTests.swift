import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class ToolingSetupTests: XCTestCase {
    func testRestartAndNavigationDoNotChangeAnyIntegration() throws {
        var writes: [ToolingPress] = []
        let controller = ToolingWindowController(facts: { self.facts() }, act: { writes.append($0) })
        controller.startSetup()
        let content = try XCTUnwrap(controller.window?.contentView)
        try button("Set Up Claude Code", in: content).performClick(nil)
        XCTAssertEqual(controller.journey?.step, .connect)
        try button("Continue →", in: content).performClick(nil)
        XCTAssertEqual(controller.journey?.step, .ready)
        controller.startSetup()
        XCTAssertEqual(controller.journey?.step, .choose)
        try button("Finish Later · Open Tooling", in: content).performClick(nil)
        XCTAssertNil(controller.journey)
        XCTAssertTrue(writes.isEmpty)
    }

    func testInstallIsExplicitAndExistingHooksCannotBeRemovedByTheGuide() throws {
        var reading = facts(hooks: .absent)
        var presses: [ToolingPress] = []
        let controller = ToolingWindowController(facts: { reading }, act: { presses.append($0) })
        controller.startSetup()
        let content = try XCTUnwrap(controller.window?.contentView)
        try button("Set Up Codex", in: content).performClick(nil)
        XCTAssertFalse(try button("Continue →", in: content).isEnabled)
        XCTAssertTrue(presses.isEmpty)
        try button("Install Connection", in: content).performClick(nil)
        XCTAssertEqual(presses, [.install(.init(source: .codex, kind: .hooks))])
        reading = facts(hooks: .unheard)
        controller.rebuild()
        XCTAssertFalse(buttons(in: content).contains { $0.title == "Remove" || $0.title == "Install Connection" })
        try button("Continue →", in: content).performClick(nil)
        XCTAssertEqual(controller.journey?.step, .verify)
    }

    /// Centred the first time, then where the person put it: the guide is followed beside a
    /// terminal, and a window that jumped back to the middle at every visit would cover it.
    func testTheWindowOpensWhereItWasLeft() throws {
        let controller = ToolingWindowController(facts: { self.facts() }, act: { _ in })
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        controller.present()
        let moved = NSPoint(x: window.frame.minX + 40, y: window.frame.minY - 30)
        window.setFrameOrigin(moved)
        window.orderOut(nil)

        controller.present()

        XCTAssertEqual(
            window.frame.origin, moved,
            "window \(window.frame), screen \(String(describing: window.screen?.frame)), "
                + "visible \(String(describing: window.screen?.visibleFrame))")
    }

    /// The sender's path is an internal detail until the entries name this very copy of the
    /// app, and then it is the one thing about to break: shown in that case only.
    func testTheSenderIsShownOnlyWhenTheHooksNameThisCopy() throws {
        let linked = ToolingWindowController(facts: { self.facts() }, act: { _ in })
        let tied = ToolingWindowController(facts: { self.facts(senderIsTiedToThisBuild: true) }, act: { _ in })

        XCTAssertFalse(texts(in: try XCTUnwrap(linked.window?.contentView)).contains("Sender"))
        let shown = texts(in: try XCTUnwrap(tied.window?.contentView))
        XCTAssertTrue(shown.contains("Sender"))
        XCTAssertTrue(shown.contains { $0.contains("moved or deleted") }, "and says what that costs")
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

    func testRenderSetupForDocumentation() throws {
        guard let directory = ProcessInfo.processInfo.environment["SETUP_RENDER_DIR"] else {
            throw XCTSkip("Set SETUP_RENDER_DIR to render the setup guide")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var reading = facts(hooks: .absent)
        let controller = ToolingWindowController(facts: { reading }, act: { _ in })
        controller.window?.appearance = NSAppearance(named: .aqua)
        controller.startSetup()
        let content = try XCTUnwrap(controller.window?.contentView)
        try draw(content, name: "setup-choose", directory: directory)
        try button("Set Up Claude Code", in: content).performClick(nil)
        try draw(content, name: "setup-connect", directory: directory)
        reading = facts(hooks: .unheard)
        controller.rebuild()
        try button("Continue →", in: content).performClick(nil)
        try draw(content, name: "setup-try", directory: directory)
        reading = facts()
        controller.rebuild()
        try draw(content, name: "setup-ready", directory: directory)
    }

    private func facts(
        hooks: ToolingInstallationState = .installed,
        senderIsTiedToThisBuild: Bool = false
    ) -> ToolingWindowFacts {
        ToolingWindowFacts(
            hookState: { _ in hooks }, statusLineState: .notSet,
            hooksPath: { $0 == .claude ? "~/.claude/skills/agent-watch/hooks/hooks.json" : "~/.codex/hooks.json" },
            statusLinePath: "~/.claude/settings.json", senderPath: "AgentWatchSend",
            senderIsTiedToThisBuild: senderIsTiedToThisBuild,
            idePlugins: [], stagedPlugin: nil, idePluginDirectoryPath: "",
            agentPaths: [.claude: "~/.local/bin/claude", .codex: "/opt/homebrew/bin/codex"],
            receivedSources: hooks == .installed ? [.claude, .codex] : [])
    }

    private func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(buttons(in: view).first { $0.title == title }, "Button: \(title)")
    }

    private func draw(_ view: NSView, name: String, directory: String) throws {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = true
            scroll.backgroundColor = .windowBackgroundColor
        }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
