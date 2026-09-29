import AgentWatchCore
import AppKit

/// What the status item's menu reads and asks for, and nothing about how it is drawn.
///
/// A protocol so that a test can stand in for the application: the menu used to be built
/// inside `AppDelegate`, which cannot be made in a test without reading the real state
/// directory, and so nothing checked a line of it.
@MainActor
protocol StatusMenuHost: AnyObject {
    /// The same counts the icon shows. Read when the menu opens.
    var attentionCounts: SessionAttentionCounts { get }
    var isWidgetVisible: Bool { get }
    var isEventDebugVisible: Bool { get }
    var checksForUpdatesOnLaunch: Bool { get set }
    var isReadingTranscripts: Bool { get }
    var transcriptFaultedSessionCount: Int { get }
    /// Every session the widget has, in the widget's order.
    var sessions: [SessionSnapshot] { get }
    func reach(for snapshot: SessionSnapshot) -> SessionReach
    /// A click on a session's line, which is a click on its row in the widget.
    func focusSession(id: String, endingAgentWasAnnounced: Bool)
    /// Called before anything is refreshed, so what the menu then reads is current.
    func menuWillOpen()
    /// Puts the registered combination on the widget line, or takes it off.
    func showShortcut(on item: NSMenuItem)
    func toggleWidget()
    func showWidgetSettings()
    func showTooling()
    func toggleEventDebug()
    func checkForUpdates()
    func resetWidgetPosition()
    func resetWidgetSize()
    func quit()
    #if AGENT_WATCH_DEBUG_CAPTURE
        /// When the current recording stops, or `nil` when none is running.
        var rawCaptureExpiry: Date? { get }
        var recordedPayloadBytes: Int { get }
        func toggleRawHookCapture()
        func deleteRawHookRecordings()
    #endif
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

    private func line(_ title: String, _ action: Selector, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.toolTip = toolTip
        return item
    }

    static func title(for retention: ClosedSessionRetention) -> String {
        switch retention {
        case .manual:
            "Keep until dismissed"
        case let .after(seconds):
            seconds < 120
                ? "Remove after \(Int(seconds)) seconds"
                : "Remove after \(Int(seconds / 60)) minutes"
        }
    }

    // MARK: - Keeping the lines true

    func menuWillOpen(_ menu: NSMenu) {
        host?.menuWillOpen()
        refresh()
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
        guard settings.listsSessionsInMenu else {
            return
        }
        let lines = menuSessionLines(
            for: host.sessions,
            listing: settings.menuSessionAttentions,
            reach: host.reach(for:)
        )
        let first = summaryItem.map { menu.index(of: $0) + 1 } ?? 0
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
            item.image = Self.mark(for: line.attention)
            menu.insertItem(item, at: first + offset)
            return item
        }
        let unlisted = lines.count - Self.listedSessionLimit
        if unlisted > 0 {
            let more = NSMenuItem(title: "\(unlisted) more in the widget", action: nil, keyEquivalent: "")
            menu.insertItem(more, at: first + sessionLineItems.count)
            sessionLineItems.append(more)
        }
    }

    /// The mark the state has in the menu bar, in its colour. The shape tells the states apart
    /// on its own, so the colour only speeds the reading (ADR-0003).
    ///
    /// Two palette colours, the mark first. Given only the accent, the palette paints every
    /// layer with it — drawn offscreen, all four came out as plain discs of four colours, which
    /// is the one thing ADR-0003 rules out. The menu bar cuts the mark out of the disc instead;
    /// a menu has a background of its own, so a white mark reads the same on a light and a dark
    /// one.
    static func mark(for attention: SessionAttention) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, attention.accent]))
        return NSImage(systemSymbolName: attention.symbolName, accessibilityDescription: attention.name)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: - Actions

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? MenuSessionLine else {
            return
        }
        host?.focusSession(id: line.sessionID, endingAgentWasAnnounced: line.endingAgentWasAnnounced)
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
