import AgentWatchCore
import AppKit

/// What the status item's menu reads and asks for, and nothing about how it is drawn.
///
/// A protocol so that a test can stand in for the application, which cannot be made in a test
/// without reading the real state directory.
@MainActor
protocol StatusMenuHost: AnyObject {
    /// The same counts the icon shows. Read when the menu opens.
    var attentionCounts: SessionAttentionCounts { get }
    /// What the agents cost together, while watching is on and the menu is to show it and a
    /// reading exists; `nil` otherwise.
    var resourceFigure: ResourceFigure? { get }
    var resourceReport: ResourceReport? { get }
    var usageLimits: [AgentUsageLimits] { get }
    var isWidgetVisible: Bool { get }
    /// Every session the widget has, in the widget's order.
    var sessions: [SessionSnapshot] { get }
    func reach(for snapshot: SessionSnapshot) -> SessionReach
    /// A click on a session's line, which is a click on its row in the widget. A broken
    /// session's answers with the question, which the menu then puts in place of its lines.
    @discardableResult
    func focusSession(id: String) -> SessionClick
    /// The yes to that question.
    func endAgent(ofSessionWithID id: String)
    /// Called before anything is refreshed, so what the menu then reads is current.
    func menuWillOpen()
    /// Puts the registered combination on the widget line, or takes it off.
    func showShortcut(on item: NSMenuItem)
    func toggleWidget()
    func showProjects()
    func showWidgetSettings()
    func quit()
}

/// The status item's menu: its lines, and keeping them true each time it opens. What it asks
/// for goes to the host.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let settingsItemTitle = "Settings…"

    let menu = NSMenu()
    private let settings: WidgetSettingsStore
    private let now: () -> Date
    private weak var host: StatusMenuHost?

    /// The lines whose title or checkmark depends on something, kept to be refreshed. Visible
    /// to the tests, which read them the way a person reads the menu.
    private(set) var summaryItem: NSMenuItem?
    /// The item that holds the session list or the question standing in its place.
    /// Rebuilt on opening, since the sessions can change between openings.
    private(set) var sessionItem: NSMenuItem?
    /// Always in the menu, so the widget is shown and hidden from the same place; its title
    /// says which a click does.
    private(set) var widgetItem: NSMenuItem?
    /// The broken session whose question stands where the session lines were, while the menu
    /// is open. A menu cannot draw over its own lines, so the lines give way to it.
    private(set) var askingAbout: String?
    /// The line clicked in the list, waiting for the menu to close: an ordinary menu line's
    /// action comes after the menu has gone, and a line in the list keeps that order.
    private var chosenLine: MenuSessionLine?
    private var usageItem: NSMenuItem?
    private var machineItem: NSMenuItem?
    /// The session lines' marks, which a theme can colour and move.
    let marks = MenuMarkAnimator()

    init(settings: WidgetSettingsStore, host: StatusMenuHost, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.host = host
        self.now = now
        super.init()
        menu.delegate = self
        build()
    }

    /// Status and the sessions, then the one window everything else lives in, then Quit.
    ///
    /// A menu bar extra is opened to see what is going on, so the menu holds nothing a person
    /// sets up once: settings, tooling and diagnostics are panes of the settings window.
    private func build() {
        let summary = NSMenuItem.sectionHeader(title: "")
        menu.addItem(summary)
        summaryItem = summary
        let widget = line("Show Widget", #selector(toggleWidget))
        menu.addItem(widget)
        widgetItem = widget
        menu.addItem(.separator())
        menu.addItem(line("Projects & Recent…", #selector(showProjects)))
        let settings = line(Self.settingsItemTitle, #selector(showWidgetSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Watch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // The summary alone, and the rest when the menu opens. Everything else asks the host
        // about collaborators it builds lazily, and building them here would build them before
        // the launch sequence means to.
        if let host {
            summary.title = MenuBarSummaryText.line(for: host.attentionCounts)
        }
    }

    private func line(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Keeping the lines true

    func menuWillOpen(_ menu: NSMenu) {
        host?.menuWillOpen()
        if let host {
            refreshDetails(host: host)
        }
        refresh()
        marks.start()
    }

    /// Closing the menu with the question open — Escape, a click elsewhere — is a no. A line
    /// clicked in the list closed the menu, and its click is carried out now.
    func menuDidClose(_ menu: NSMenu) {
        askingAbout = nil
        marks.stop()
        if let line = chosenLine {
            chosenLine = nil
            focusSession(line)
        }
    }

    /// Every title and checkmark, read again from what they describe.
    func refresh() {
        guard let host else {
            return
        }
        refreshSummary()
        refreshSessions()
        widgetItem?.title = host.isWidgetVisible ? "Hide Widget" : "Show Widget"
        if let widgetItem {
            host.showShortcut(on: widgetItem)
        }
    }

    /// The first line, read again from the counts — on opening, and whenever the icon's counts
    /// move, the menu open or not. The one line kept live: it is never a target, so nothing can
    /// move out from under a click. The session lines below it keep their wording until the
    /// menu opens again, and a click on one is checked against the session as it is then.
    ///
    /// With the agents' figure the line is drawn by `MenuSummaryView`, which looks the same; the
    /// title stays the phrase either way. Without it the line is the menu's own header again.
    func refreshSummary() {
        guard let host, let summaryItem else {
            return
        }
        let phrase = MenuBarSummaryText.line(for: host.attentionCounts)
        summaryItem.title = phrase
        guard let figure = host.resourceFigure else {
            summaryItem.view = nil
            return
        }
        let view = summaryItem.view as? MenuSummaryView ?? MenuSummaryView()
        view.show(phrase: phrase, figure: ResourceFormat.short(figure), spoken: ResourceFormat.spoken(figure))
        if summaryItem.view !== view {
            summaryItem.view = view
        }
    }

    /// The summary as drawn with the figure beside it, while it is.
    var summaryView: MenuSummaryView? {
        summaryItem?.view as? MenuSummaryView
    }

    /// Keep the details in place until the menu reopens so rows never move under the pointer.
    private func refreshDetails(host: StatusMenuHost) {
        if let usageItem { menu.removeItem(usageItem) }
        if let machineItem { menu.removeItem(machineItem) }
        usageItem = nil
        machineItem = nil

        if settings.showsUsageLimitsInMenu, let summaryItem {
            let limits = host.usageLimits.sorted { $0.source.rawValue < $1.source.rawValue }
            if !limits.isEmpty {
                let moment = now()
                let title = limits.map { widgetUsageText(for: $0, compactAt: moment) }.joined(separator: "  |  ")
                let item = NSMenuItem.sectionHeader(title: title)
                item.toolTip = limits.map { widgetUsageText(for: $0) }.joined(separator: "\n")
                menu.insertItem(item, at: menu.index(of: summaryItem) + 1)
                usageItem = item
            }
        }
        if settings.showsMachineResourcesInMenu, let widgetItem, let machine = host.resourceReport?.machineFigure {
            var parts = ["Mac", "\(ResourceFormat.memory(machine.used)) RAM"]
            if let load = machine.load, let cores = machine.cores, cores > 0 {
                parts.append("\(ResourceFormat.percent(load / Double(cores))) CPU")
            }
            let item = NSMenuItem.sectionHeader(title: parts.joined(separator: " · "))
            item.toolTip = ResourceFormat.memoryInUse(machine)
            menu.insertItem(item, at: menu.index(of: widgetItem))
            machineItem = item
        }
    }

    /// The listed sessions, read again from the setting and the sessions. Called on opening,
    /// and while the menu is open when its lines have to change under the pointer: the
    /// question of a broken session puts itself in their place, and Cancel puts them back.
    func refreshSessions() {
        if let host {
            showSessionLines(host: host)
        }
    }

    /// Between the summary rows and the actions below.
    private func showSessionLines(host: StatusMenuHost) {
        if let sessionItem {
            menu.removeItem(sessionItem)
        }
        sessionItem = nil
        marks.show([])
        guard settings.listsSessionsInMenu else {
            return
        }
        let lines = menuSessionLines(
            for: host.sessions,
            listing: settings.menuSessionAttentions,
            reach: host.reach(for:)
        )
        let first = (usageItem ?? summaryItem).map { menu.index(of: $0) + 1 } ?? 0
        // Asked again on every rebuild, as the widget does.
        if let askingAbout, let session = host.sessions.first(where: { $0.id == askingAbout }),
            EndAgentQuestion.holds(for: session, reach: host.reach(for:))
        {
            let item = questionItem(for: session)
            menu.insertItem(item, at: first)
            sessionItem = item
            return
        }
        askingAbout = nil
        guard !lines.isEmpty else {
            return
        }
        let look = ThemeInUse.look
        let styles = lines.map { look.menuMarkStyle(for: $0.phase, phases: ThemeInUse.phases) }
        let list = MenuSessionListView(
            lines: lines,
            images: zip(lines, styles).map { MenuMarkAnimator.mark(for: $0.attention, colour: $1.color) },
            visibleCount: settings.menuSessionsBeforeScrolling
        )
        list.onChoose = { [weak self] line in
            self?.choose(line)
        }
        // No action: a menu that enables its own items reads the list as disabled, and the
        // arrows step over a disabled line instead of stopping on one that draws no highlight.
        let item = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        item.view = list
        menu.insertItem(item, at: first)
        sessionItem = item
        marks.show(zip(list.rows, styles).map { row, style in (row, row.line.attention, style) })
    }

    /// The list of sessions under the summary, while it is shown.
    var sessionList: MenuSessionListView? {
        sessionItem?.view as? MenuSessionListView
    }

    /// The mark the state has in the menu bar, in the state's colour (`MenuMarkAnimator.mark`).
    static func mark(for attention: SessionAttention) -> NSImage? {
        MenuMarkAnimator.mark(for: attention, colour: attention.accent)
    }

    /// The question, as tall as it needs to be at the menu's width, with the rest of the
    /// menu around it.
    private func questionItem(for session: SessionSnapshot) -> NSMenuItem {
        let reason = EndAgentReason(for: session)
        let item = NSMenuItem(title: EndAgentDialog.heading(for: reason), action: nil, keyEquivalent: "")
        let id = session.id
        item.view = MenuEndAgentQuestionView(
            sessionID: id,
            sessionName: EndAgentQuestion.name(of: session),
            reason: reason,
            onCancel: { [weak self] in
                self?.askingAbout = nil
                self?.refreshSessions()
            },
            onEnd: { [weak self] in
                self?.askingAbout = nil
                self?.host?.endAgent(ofSessionWithID: id)
                // Closed rather than kept: the lines are read once per opening, and an open
                // menu would go on listing the session the answer just ended.
                self?.menu.cancelTracking()
            }
        )
        return item
    }

    /// A broken session's or a headless run's line, which stays open for the question its
    /// click leads to.
    func chooseBrokenLine(_ line: MenuSessionLine) {
        guard case .asksToEndAgent = host?.focusSession(id: line.sessionID) else {
            refreshSessions()
            return
        }
        askingAbout = line.sessionID
        refreshSessions()
    }

    // MARK: - Actions

    /// A click on a line in the list. A broken session's asks its question in the open menu;
    /// any other closes the menu first and is carried out once it has gone (`menuDidClose`).
    func choose(_ line: MenuSessionLine) {
        guard line.isEnabled else {
            return
        }
        if line.leadsToQuestion {
            chooseBrokenLine(line)
            return
        }
        chosenLine = line
        menu.cancelTracking()
    }

    /// The one broken session that can only be found by a click — a tab Ghostty closed and
    /// kept — is found here, after the menu has gone: its row is marked, and the next opening
    /// of the menu shows its line, which asks.
    private func focusSession(_ line: MenuSessionLine) {
        host?.focusSession(id: line.sessionID)
    }

    @objc private func toggleWidget() {
        host?.toggleWidget()
    }

    @objc private func showProjects() {
        host?.showProjects()
    }

    @objc private func showWidgetSettings() {
        host?.showWidgetSettings()
    }

    @objc private func quit() {
        host?.quit()
    }
}
