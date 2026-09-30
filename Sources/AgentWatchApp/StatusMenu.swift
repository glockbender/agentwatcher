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
    func showWidgetSettings()
    func quit()
}

/// The status item's menu: its lines, and keeping them true each time it opens.
///
/// Settings are written straight to the store, whose `onChange` carries the follow-up; the
/// rest goes to the host.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let settings: WidgetSettingsStore
    private weak var host: StatusMenuHost?

    /// The lines whose title or checkmark depends on something, kept to be refreshed. Visible
    /// to the tests, which read them the way a person reads the menu.
    private(set) var summaryItem: NSMenuItem?
    /// One line per listed session, directly under the summary. Rebuilt each time rather
    /// than kept in step: they are a handful, and the list changes between two openings.
    private(set) var sessionLineItems: [NSMenuItem] = []
    /// Shown only while the widget is hidden, so a hidden widget is never lost.
    private(set) var widgetItem: NSMenuItem?
    /// At most this many sessions are listed; the rest are counted on one line.
    static let listedSessionLimit = 8
    /// The broken session whose question stands where the session lines were, while the menu
    /// is open. A menu cannot draw over its own lines, so the lines give way to it.
    private(set) var askingAbout: String?
    /// The session lines' marks, which a theme can colour and move.
    let marks = MenuMarkAnimator()

    init(settings: WidgetSettingsStore, host: StatusMenuHost) {
        self.settings = settings
        self.host = host
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
        let settings = line("Settings…", #selector(showWidgetSettings))
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
        refresh()
        marks.start()
    }

    /// Closing the menu with the question open — Escape, a click elsewhere — is a no.
    func menuDidClose(_ menu: NSMenu) {
        askingAbout = nil
        marks.stop()
    }

    /// Every title and checkmark, read again from what they describe.
    func refresh() {
        guard let host else {
            return
        }
        refreshSummary()
        refreshSessions()
        widgetItem?.isHidden = host.isWidgetVisible
        if let widgetItem {
            host.showShortcut(on: widgetItem)
        }
    }

    /// The first line, read again from the counts — on opening, and whenever the icon's counts
    /// move, the menu open or not. The one line kept live: it is never a target, so nothing can
    /// move out from under a click. The session lines below it keep their wording until the
    /// menu opens again, and a click on one is checked against the session as it is then.
    func refreshSummary() {
        guard let host else {
            return
        }
        summaryItem?.title = MenuBarSummaryText.line(for: host.attentionCounts)
    }

    /// The listed sessions and the lines that choose them, read again from the setting. Called
    /// straight after a choice as well as on opening: the menu is still open then, and the
    /// lines at its top show the effect while the pointer is still in the submenu.
    func refreshSessions() {
        if let host {
            showSessionLines(host: host)
        }
    }

    /// Under the summary, so the line that counts the sessions reads as the heading of the
    /// list of them.
    private func showSessionLines(host: StatusMenuHost) {
        for item in sessionLineItems {
            menu.removeItem(item)
        }
        sessionLineItems = []
        marks.show([])
        guard settings.listsSessionsInMenu else {
            return
        }
        let lines = menuSessionLines(
            for: host.sessions,
            listing: settings.menuSessionAttentions,
            reach: host.reach(for:)
        )
        let first = summaryItem.map { menu.index(of: $0) + 1 } ?? 0
        // Asked again on every rebuild, as the widget does.
        if let askingAbout, let session = host.sessions.first(where: { $0.id == askingAbout }),
            EndAgentQuestion.holds(for: session, reach: host.reach(for:))
        {
            let item = questionItem(for: session)
            menu.insertItem(item, at: first)
            sessionLineItems = [item]
            return
        }
        askingAbout = nil
        let look = ThemeInUse.look
        var marked: [(item: NSMenuItem, attention: SessionAttention, style: LampStyle)] = []
        sessionLineItems = lines.prefix(Self.listedSessionLimit).enumerated().map { offset, line in
            // A line with nothing to do has no action, which is how a menu that enables its
            // own items knows to grey it: `isEnabled` alone is overwritten when it opens.
            let item = NSMenuItem(
                title: line.title,
                action: line.isEnabled ? #selector(focusSession(_:)) : nil,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = line
            let style = look.menuMarkStyle(for: line.phase, phases: ThemeInUse.phases)
            item.image = MenuMarkAnimator.mark(for: line.attention, colour: style.color)
            if line.leadsToQuestion {
                // Still: the line draws itself, and its picture is taken once.
                let view = MenuBrokenSessionLineView(title: line.title, image: item.image)
                view.onChoose = { [weak self] in
                    self?.chooseBrokenLine(line)
                }
                item.view = view
            } else {
                marked.append((item, line.attention, style))
            }
            menu.insertItem(item, at: first + offset)
            return item
        }
        marks.show(marked)
        let unlisted = lines.count - Self.listedSessionLimit
        if unlisted > 0 {
            let more = NSMenuItem(title: "\(unlisted) more in the widget", action: nil, keyEquivalent: "")
            menu.insertItem(more, at: first + sessionLineItems.count)
            sessionLineItems.append(more)
        }
    }

    /// The mark the state has in the menu bar, in the state's colour (`MenuMarkAnimator.mark`).
    static func mark(for attention: SessionAttention) -> NSImage? {
        MenuMarkAnimator.mark(for: attention, colour: attention.accent)
    }

    /// The question, as tall as it needs to be at the menu's width, with the rest of the
    /// menu around it.
    private func questionItem(for session: SessionSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Broken session", action: nil, keyEquivalent: "")
        let id = session.id
        item.view = MenuEndAgentQuestionView(
            sessionID: id,
            sessionName: EndAgentQuestion.name(of: session),
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

    /// A broken session's line, which stays open for the question its click leads to.
    func chooseBrokenLine(_ line: MenuSessionLine) {
        guard case .asksToEndAgent = host?.focusSession(id: line.sessionID) else {
            refreshSessions()
            return
        }
        askingAbout = line.sessionID
        refreshSessions()
    }

    // MARK: - Actions

    /// An ordinary line, whose click closes the menu. The one broken session that can only be
    /// found by a click — a tab Ghostty closed and kept — is found here, after the menu has
    /// gone: its row is marked, and the next opening of the menu shows its line, which asks.
    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? MenuSessionLine else {
            return
        }
        if line.leadsToQuestion {
            chooseBrokenLine(line)
            return
        }
        host?.focusSession(id: line.sessionID)
    }

    @objc private func toggleWidget() {
        host?.toggleWidget()
    }

    @objc private func showWidgetSettings() {
        host?.showWidgetSettings()
    }

    @objc private func quit() {
        host?.quit()
    }
}
