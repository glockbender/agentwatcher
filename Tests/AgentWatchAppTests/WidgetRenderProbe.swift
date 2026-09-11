import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// Draws the widget into PNG files so its appearance can be checked without a screen grab.
///
/// Skipped unless `WIDGET_RENDER_DIR` names a directory, so it costs nothing in the ordinary
/// run. It exists because a widget can pass every measurement and still look wrong, and
/// because capturing a region of the screen would capture whatever else is under it:
/// `cacheDisplay` draws only these views, into a bitmap, with no screen involved.
///
///     WIDGET_RENDER_DIR=/tmp/render swift test --filter WidgetRenderProbe
@MainActor
final class WidgetRenderProbe: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    func testDrawTheWidget() throws {
        let requested = ProcessInfo.processInfo.environment["WIDGET_RENDER_DIR"]
        try XCTSkipIf(requested == nil, "a drawing probe, not a check: set WIDGET_RENDER_DIR")
        let directory = try XCTUnwrap(requested)

        try draw(listView(width: 420), named: "wide", in: directory)
        try draw(highlightedWidget(.left), named: "edge-left", in: directory)
        try draw(highlightedWidget(.bottomRight), named: "edge-corner", in: directory)
        try draw(listView(width: 190), named: "narrow", in: directory)
        try draw(crampedList(), named: "cramped", in: directory)
        try draw(hoverCard(), named: "card", in: directory)
        try draw(emptyState(complaint: nil), named: "empty", in: directory)
        try draw(
            emptyState(complaint: toolingComplaint(states: [.absent, .absent])),
            named: "empty-nothing-installed",
            in: directory
        )
        try draw(
            emptyState(complaint: toolingComplaint(states: [.absent, .absent]), width: 190),
            named: "empty-nothing-installed-narrow",
            in: directory
        )
        try draw(settingsWindowContent(), named: "settings", in: directory)
        try draw(toolingWindowContent(), named: "tooling", in: directory)
        try draw(toolingWindowOnThisMachine(), named: "tooling-here", in: directory)
    }

    /// The tooling window with one of each interesting state on screen at once: an agent
    /// that is installed and delivering, one whose records have never fired, a status line
    /// somebody else's command already holds, and three IDEs that stand in three different
    /// places. Drawn rather than measured because this window is mostly sentences, and a wall
    /// of text is exactly what measures right and reads wrong.
    private func toolingWindowContent() throws -> NSView {
        let controller = ToolingWindowController(
            facts: { [idePlugins] in
                ToolingWindowFacts(
                    hookState: { $0 == .claude ? .installed : .unheard },
                    statusLineState: .theirs(command: "~/bin/my-status-line.sh"),
                    hooksPath: {
                        switch $0 {
                        case .claude: "/Users/someone/.claude/skills/agent-watch/hooks.json"
                        case .codex: "/Users/someone/.codex/hooks.json"
                        }
                    },
                    statusLinePath: "/Users/someone/.claude/settings.json",
                    senderPath: "/Users/someone/Library/Application Support/AgentWatch/AgentWatchSend",
                    senderIsTiedToThisBuild: false,
                    idePlugins: idePlugins(),
                    stagedPlugin: StagedIDEPlugin(fileName: "agent-watch-ide-0.1.3.zip", version: "0.1.3"),
                    idePluginDirectoryPath: "/Users/someone/Library/Application Support/AgentWatch/ide-plugin"
                )
            },
            act: { _ in }
        )
        // The document rather than the window's own view: the content scrolls now, and
        // drawing the window would draw as much of it as the screen happens to allow.
        let scroll = try XCTUnwrap(controller.window?.contentView as? NSScrollView)
        let view = try XCTUnwrap(scroll.documentView)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The settings window as it opens, with nothing chosen yet — nine lamp rows, the
    /// palette and the opacity slider. Drawn rather than measured because a grid of colour
    /// wells and pop-up buttons is exactly the layout that measures right and reads wrong.
    private func settingsWindowContent() throws -> NSView {
        let preferences = try isolatedPreferences()
        let controller = WidgetSettingsWindowController(
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: LampSchemeStore(preferences: preferences)
        )
        let view = try XCTUnwrap(controller.window?.contentView)
        // The window's own background, which `cacheDisplay` does not draw: without it the
        // labels come out white on nothing and the image reads as a window with no text.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The same window with the IDE section reading this machine instead of a fixture.
    ///
    /// The one part of that section no fixture can check: whether the search finds the IDEs a
    /// person actually has, and whether the plugin's own reply is read back. Every other row
    /// is drawn from values, so this scene deliberately leaves them at their defaults.
    private func toolingWindowOnThisMachine() throws -> NSView {
        let staged = IDEPluginFiles.staged()
        let isDaemonInstalled = JetBrainsInstallation.isDaemonInstalled()
        let readings = JetBrainsIDEs.installed().map { ide in
            IDEPluginReading(
                ide: ide,
                presence: IDEPluginInstallation.presence(
                    productScheme: ide.productScheme,
                    isDaemonInstalled: isDaemonInstalled,
                    reply: IDEPluginFiles.reply(forDataDirectoryName: ide.product.dataDirectoryName),
                    check: .notAsked
                )
            )
        }
        let controller = ToolingWindowController(
            facts: {
                ToolingWindowFacts(
                    hookState: { _ in .installed },
                    statusLineState: .connected,
                    hooksPath: { _ in "—" },
                    statusLinePath: "—",
                    senderPath: "—",
                    senderIsTiedToThisBuild: false,
                    idePlugins: readings,
                    stagedPlugin: staged?.plugin,
                    idePluginDirectoryPath: IDEPluginFiles.pluginDirectory()?.path ?? ""
                )
            },
            act: { _ in }
        )
        let scroll = try XCTUnwrap(controller.window?.contentView as? NSScrollView)
        let view = try XCTUnwrap(scroll.documentView)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - The scenes

    /// Three IDEs standing in the three places that read differently: one running with an
    /// older plugin in it, one running that has never answered, and one that is not running
    /// at all and so cannot be asked anything.
    private func idePlugins() -> [IDEPluginReading] {
        [
            IDEPluginReading(
                ide: ide("GoLand", version: "2026.1.4", directory: "GoLand2026.1", scheme: "goland", running: true),
                presence: .answeredEarlier(
                    IDEPluginReply(
                        token: "kh2l0bfzomrpl7o4",
                        pluginVersion: "0.1.2",
                        ideBuild: "GO-261.26222.72",
                        answeredAt: now
                    )
                )
            ),
            IDEPluginReading(
                ide: ide("PyCharm", version: "2026.1.4", directory: "PyCharm2026.1", scheme: "pycharm", running: true),
                presence: .neverAnswered
            ),
            IDEPluginReading(
                ide: ide(
                    "IntelliJ IDEA",
                    version: "2026.1.1",
                    directory: "IntelliJIdea2026.1",
                    scheme: "idea",
                    running: false
                ),
                presence: .neverAnswered
            ),
        ]
    }

    private func ide(
        _ name: String,
        version: String,
        directory: String,
        scheme: String,
        running: Bool
    ) -> InstalledJetBrainsIDE {
        InstalledJetBrainsIDE(
            product: JetBrainsProduct(name: name, version: version, dataDirectoryName: directory),
            bundlePath: "/Users/someone/Applications/\(name).app",
            productScheme: scheme,
            isRunning: running
        )
    }

    /// One session of each interesting kind, so a single image answers most questions.
    private func sessions() -> [SessionSnapshot] {
        var working = session(0, "AGENTS.md интеграция в CLAUDE.md", .executing, secondsAgo: 8)
        // One of each kind that a Claude session can really produce, so the drawing shows
        // whether they are told apart at a glance.
        working.activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: now),
            SessionActivity(id: "agent", kind: .subagent, startedAt: now, outlivesTurn: true),
            SessionActivity(
                id: "background",
                kind: .backgroundTask,
                startedAt: now,
                outlivesItsCall: true
            ),
        ]
        working.contextTelemetry = .init(totalInputTokens: 333_000)

        var waiting = session(1, "Переписать ingress", .waitingForUser, secondsAgo: 95)
        waiting.userInputRequestKind = .approval

        var compacting = session(5, "Сжатие контекста", .executing, secondsAgo: 4)
        compacting.activities = [
            SessionActivity(id: "compaction", kind: .compaction, startedAt: now)
        ]

        // The one activity no hook announces. Drawn beside the wrench and the two figures so
        // the three symbols can be told apart at the size a row actually uses.
        var consulting = session(8, "Совет по расписанию чтения", .executing, secondsAgo: 40)
        consulting.activities = [
            SessionActivity(id: "advisor", kind: .advisor, startedAt: now),
            SessionActivity(id: "tool", kind: .tool, startedAt: now),
        ]

        // The turn is over and a detached command is still running — the state the widget
        // used to show as finished with nothing in the row.
        var background = session(7, "Фоновый скрипт после хода", .waitingForChildren, secondsAgo: 175)
        background.activities = [
            SessionActivity(
                id: "detached",
                kind: .backgroundTask,
                startedAt: now,
                outlivesTurn: true,
                outlivesItsCall: true
            )
        ]

        var codex = session(2, "Мониторинг AI-сессий", .completed, secondsAgo: 400)
        codex.clientKind = .desktop
        // The only agent that says what its count is a fraction of, so the only row that can
        // show a share. The row above it shows the fallback — a bare count — for the agent
        // that cannot.
        codex.contextTelemetry = .init(totalInputTokens: 1_970_000, usedPercentage: 87)

        var lost = session(3, "Разбор падения тестов", .disconnected, secondsAgo: 4_000)
        lost.gitBranch = "main"

        // A session nobody has named yet — the first seconds of every session, a session
        // left at its prompt, and any Codex thread missing from the index. It is here for
        // the stand-in the row puts in place of the name, which has to be readable beside
        // real names and has to survive the widget getting narrow.
        var unnamed = session(6, nil, .executing, secondsAgo: 2)
        unnamed.projectName = "sample-cli"

        // An agent the app has never heard a hook from, found by its process alone. It has
        // no name and no phase to show, so the drawing answers the question those two
        // absences raise: whether the row still reads as a session.
        let discovered = DiscoveredAgentProcess(
            source: .claude,
            processID: 4_242,
            startedAt: now.addingTimeInterval(-1_500),
            projectName: "agent-watch"
        ).row(arrivalIndex: 9)

        return [
            working, waiting, compacting, consulting, background, unnamed, codex, lost,
            session(4, "Старая сессия", .sessionClosed, secondsAgo: 30), discovered,
        ]
    }

    /// Both empty states side by side. The one that asks for an integration is the first
    /// thing a person sees on a machine where nothing is installed, and it is the only place
    /// the app is allowed to ask for anything at all.
    private func emptyState(complaint: String?, width: CGFloat = 420) -> HUDEmptyStateView {
        let view = HUDEmptyStateView(background: .graphite, backgroundOpacity: 1, complaint: complaint)
        place(view, size: NSSize(width: width, height: 64))
        return view
    }

    private func listView(width: CGFloat) -> HUDSessionListView {
        let list = HUDSessionListView(
            sessions: sessions(),
            usageLimits: [AgentUsageLimits(source: .claude, fiveHour: .init(usedPercentage: 17), observedAt: now)],
            now: now,
            availableWidth: width,
            showsSessionTopic: true,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
        let height = HUDSessionListView.selfSizedHeight(
            sessionCount: sessions().count,
            usageLimits: [AgentUsageLimits(source: .claude, fiveHour: .init(usedPercentage: 17), observedAt: now)],
            background: .graphite
        )
        place(list, size: NSSize(width: width, height: height))
        return list
    }

    /// A widget too short for its sessions, which is the only state where the `▾ N more`
    /// badge is on screen. Drawn because the badge lies over a row: what it has to prove is
    /// that it reads as a separate mark rather than as part of the row it covers.
    private func crampedList() -> HUDSessionListView {
        let list = listView(width: 420)
        place(list, size: NSSize(width: 420, height: 150))
        list.layoutSubtreeIfNeeded()
        return list
    }

    /// The widget with one border strip lit, which is what replaces a resize cursor the
    /// widget cannot have: a cursor appears only over the window holding keyboard focus, and
    /// this one refuses focus so that clicking it never interrupts typing elsewhere.
    private func highlightedWidget(_ edge: WidgetEdgeHighlightView.Edge) -> NSView {
        let width: CGFloat = 420
        let container = HUDContentContainer()
        let list = listView(width: width)
        container.setBody(list)
        place(container, size: NSSize(width: width, height: list.frame.height))
        container.layoutSubtreeIfNeeded()
        let overlay = container.subviews.compactMap { $0 as? WidgetEdgeHighlightView }.last
        let point =
            switch edge {
            case .left: NSPoint(x: 1, y: container.bounds.midY)
            case .bottomRight: NSPoint(x: container.bounds.maxX - 1, y: 1)
            default: NSPoint(x: container.bounds.midX, y: 1)
            }
        overlay?.highlight(at: point)
        return container
    }

    /// Built the way `SessionHoverCard` builds it, which is what makes the image worth
    /// looking at — a mock-up of a card would only prove the mock-up looks right.
    private func hoverCard() -> NSView {
        let text = hoverCardText(
            for: sessions()[0],
            now: now,
            locator: SessionLocator(applicationName: "GoLand", projectName: "mcp-hub", tabName: "x")
        )
        let label = NSTextField(labelWithString: text)
        label.font = WidgetStyle.secondaryFont
        // Wrapping, as the card itself does. Without it a long line was drawn clipped here
        // and read as a defect the card does not have.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 324
        let size = label.sizeThatFits(NSSize(width: 324, height: CGFloat.greatestFiniteMagnitude))

        let card = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        card.layer?.cornerRadius = WidgetStyle.panelCornerRadius
        label.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        card.addSubview(label)
        card.layoutSubtreeIfNeeded()
        return card
    }

    // MARK: - Drawing

    private func draw(_ view: NSView, sized size: NSSize? = nil, named name: String, in directory: String) throws {
        if let size {
            place(view, size: size)
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("drew \(url.path) at \(rep.pixelsWide)×\(rep.pixelsHigh)")
    }

    /// A window, because a view outside one lays out against nothing.
    private func place(_ view: NSView, size: NSSize) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
    }

    private func session(
        _ index: Int,
        _ title: String?,
        _ phase: SessionPhase,
        secondsAgo: TimeInterval
    ) -> SessionSnapshot {
        testSession(
            index: index,
            source: index == 2 ? .codex : .claude,
            title: title,
            phase: phase,
            clientKind: .cli,
            lastObservedAt: now.addingTimeInterval(-secondsAgo)
        )
    }
}
