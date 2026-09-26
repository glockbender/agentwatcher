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
    /// Called before anything is refreshed, so what the menu then reads is current.
    func menuWillOpen()
    /// Puts the registered combination on the widget line, or takes it off.
    func showShortcut(on item: NSMenuItem)
    func toggleWidget()
    func highlightWidget()
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
    private let version: String?
    private weak var host: StatusMenuHost?

    /// The lines whose title or checkmark depends on something, kept to be refreshed. Visible
    /// to the tests, which read them the way a person reads the menu.
    private(set) var summaryItem: NSMenuItem?
    private(set) var countsItem: NSMenuItem?
    private(set) var widgetItem: NSMenuItem?
    private(set) var debugItem: NSMenuItem?
    private(set) var lockPositionItem: NSMenuItem?
    private(set) var lockSizeItem: NSMenuItem?
    private(set) var updateOnLaunchItem: NSMenuItem?
    private(set) var closedSessionItems: [NSMenuItem] = []
    private(set) var transcriptItems: [NSMenuItem] = []
    private(set) var transcriptSummaryItem: NSMenuItem?
    #if AGENT_WATCH_DEBUG_CAPTURE
        private(set) var rawCaptureItem: NSMenuItem?
        private(set) var deleteRecordingsItem: NSMenuItem?
    #endif

    init(settings: WidgetSettingsStore, version: String?, host: StatusMenuHost) {
        self.settings = settings
        self.version = version
        self.host = host
        super.init()
        menu.delegate = self
        build()
    }

    private func build() {
        // First, and never clickable: what the icon means, spelled out. The icon is read at a
        // glance and the menu is opened when the glance was not enough.
        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary
        let counts = line("Show Counts in Menu Bar", #selector(toggleMenuBarCounts))
        menu.addItem(counts)
        countsItem = counts
        menu.addItem(.separator())
        let widget = line("Show Widget", #selector(toggleWidget))
        menu.addItem(widget)
        widgetItem = widget
        menu.addItem(line("Highlight Widget", #selector(highlightWidget)))
        // No key equivalent. This application is an accessory and is never the active one, so a
        // shortcut printed here would answer nothing anywhere but inside the open menu — a
        // promise the menu cannot keep. The line above it is the exception, and it earns the
        // exception: something registered that combination with the system, which is what
        // `WidgetShortcutController` is for. Nothing else here has asked to be worth that.
        menu.addItem(line("Widget Settings…", #selector(showWidgetSettings)))
        menu.addItem(makeBehaviorMenuItem())
        let debug = line("Show Event Debug", #selector(toggleEventDebug))
        menu.addItem(debug)
        debugItem = debug
        // One line and a window behind it. This used to be a submenu whose every line was
        // both the state and the switch, and the answer stopped fitting on a menu line once
        // it had to carry the sender's path and the step Codex still needs from a person.
        menu.addItem(line("Tooling…", #selector(showTooling)))
        menu.addItem(makeTranscriptMenuItem())
        menu.addItem(makeUpdateMenuItem())
        #if AGENT_WATCH_DEBUG_CAPTURE
            let rawCapture = line("Record Raw Hook Payloads for 30 Minutes", #selector(toggleRawHookCapture))
            rawCapture.toolTip = "Debug only: saves original hook payloads locally for a limited time"
            menu.addItem(rawCapture)
            rawCaptureItem = rawCapture
            let deleteRecordings = line("Delete Recorded Payloads", #selector(deleteRawHookRecordings))
            menu.addItem(deleteRecordings)
            deleteRecordingsItem = deleteRecordings
        #endif
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

    private func makeBehaviorMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Widget Behavior", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Widget Behavior")
        let lockPosition = line(
            "Lock Position", #selector(toggleLockPosition),
            toolTip: "Stops an accidental drag from moving the widget"
        )
        submenu.addItem(lockPosition)
        lockPositionItem = lockPosition
        let lockSize = line(
            "Lock Size", #selector(toggleLockSize),
            toolTip: "Stops an accidental drag on an edge from resizing the widget"
        )
        submenu.addItem(lockSize)
        lockSizeItem = lockSize
        submenu.addItem(
            line(
                "Reset Widget Position", #selector(resetWidgetPosition),
                toolTip: "Brings the widget back to the middle of the main screen"
            ))
        submenu.addItem(
            line(
                "Reset Widget Size", #selector(resetWidgetSize),
                toolTip: "Lets the widget size itself to the number of sessions again"
            ))
        submenu.addItem(.separator())
        submenu.addItem(makeClosedSessionMenuItem())
        item.submenu = submenu
        return item
    }

    private func makeClosedSessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Closed Sessions", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Closed Sessions")
        closedSessionItems = WidgetSettingsStore.offeredClosedSessionRetentions.map { retention in
            let entry = line(Self.title(for: retention), #selector(selectClosedSessionRetention(_:)))
            entry.representedObject = retention.seconds
            submenu.addItem(entry)
            return entry
        }
        item.submenu = submenu
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

    /// The second source of truth, and the only setting that can turn it off.
    ///
    /// Its own menu rather than a line in `Widget Behavior`, because it is not about the
    /// widget: it decides how much the app can know about a session, and it is where a
    /// failure to read is reported.
    private func makeTranscriptMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Read Session Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Read Session Transcripts")
        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        submenu.addItem(summary)
        transcriptSummaryItem = summary
        submenu.addItem(.separator())
        transcriptItems = WidgetSettingsStore.offeredTranscriptPollIntervals.map { interval in
            let entry = line(
                transcriptIntervalMenuTitle(interval: interval),
                #selector(selectTranscriptPollInterval(_:))
            )
            // Zero stands for off. An absent `representedObject` cannot be told apart from
            // one that was never set, and "off" has to be a choice like the others.
            entry.representedObject = NSNumber(value: interval ?? 0)
            submenu.addItem(entry)
            return entry
        }
        item.submenu = submenu
        return item
    }

    /// The version this copy is, and the two decisions about newer ones.
    ///
    /// A submenu rather than a line, because the version belongs in the interface somewhere:
    /// it is the first thing anybody reporting a problem is asked for, and an app with no
    /// window of its own has nowhere else to put it.
    private func makeUpdateMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let versionItem = NSMenuItem(
            title: version.map { "Agent Watch \($0)" } ?? "Agent Watch (development build)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        submenu.addItem(versionItem)
        submenu.addItem(.separator())
        submenu.addItem(line("Check for Updates…", #selector(checkForUpdates)))
        let onLaunch = line("Check on Launch", #selector(toggleUpdateCheckOnLaunch))
        submenu.addItem(onLaunch)
        updateOnLaunchItem = onLaunch
        item.submenu = submenu
        return item
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
        summaryItem?.title = MenuBarSummaryText.line(for: host.attentionCounts)
        countsItem?.state = settings.showsMenuBarCounts ? .on : .off
        widgetItem?.title = host.isWidgetVisible ? "Hide Widget" : "Show Widget"
        if let widgetItem {
            host.showShortcut(on: widgetItem)
        }
        debugItem?.title = host.isEventDebugVisible ? "Hide Event Debug" : "Show Event Debug"
        lockPositionItem?.state = settings.locksPosition ? .on : .off
        lockSizeItem?.state = settings.locksSize ? .on : .off
        updateOnLaunchItem?.state = host.checksForUpdatesOnLaunch ? .on : .off
        let retention = settings.closedSessionRetention.seconds
        for item in closedSessionItems {
            item.state = item.representedObject as? TimeInterval == retention ? .on : .off
        }
        let interval = settings.transcriptPollInterval
        for item in transcriptItems {
            let seconds = (item.representedObject as? NSNumber)?.doubleValue ?? 0
            item.state = (seconds > 0 ? seconds : nil) == interval ? .on : .off
        }
        transcriptSummaryItem?.title = transcriptMenuSummary(
            interval: interval,
            isReading: host.isReadingTranscripts,
            faultedSessionCount: host.transcriptFaultedSessionCount
        )
        #if AGENT_WATCH_DEBUG_CAPTURE
            refreshRawHookCapture(host: host)
        #endif
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        private func refreshRawHookCapture(host: StatusMenuHost, now: Date = .now) {
            // Shown only when there is something to delete, so its presence is itself the
            // answer to "is any of this still on disk", which nothing used to state.
            if let deleteItem = deleteRecordingsItem {
                let bytes = host.recordedPayloadBytes
                deleteItem.isHidden = bytes == 0
                deleteItem.title =
                    "Delete Recorded Payloads"
                    + " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            }
            guard let item = rawCaptureItem else {
                return
            }
            guard let expiry = host.rawCaptureExpiry, expiry > now else {
                item.title = "Record Raw Hook Payloads for 30 Minutes"
                item.state = .off
                return
            }
            let remainingMinutes = max(1, Int(ceil(expiry.timeIntervalSince(now) / 60)))
            item.title = "Stop Recording Raw Hook Payloads (\(remainingMinutes)m)"
            item.state = .on
        }
    #endif

    // MARK: - Actions

    @objc private func toggleMenuBarCounts() {
        settings.setShowsMenuBarCounts(!settings.showsMenuBarCounts)
    }

    @objc private func toggleWidget() {
        host?.toggleWidget()
    }

    @objc private func highlightWidget() {
        host?.highlightWidget()
    }

    @objc private func showWidgetSettings() {
        host?.showWidgetSettings()
    }

    @objc private func toggleEventDebug() {
        host?.toggleEventDebug()
    }

    @objc private func showTooling() {
        host?.showTooling()
    }

    @objc private func checkForUpdates() {
        host?.checkForUpdates()
    }

    @objc private func toggleUpdateCheckOnLaunch() {
        host?.checksForUpdatesOnLaunch.toggle()
    }

    @objc private func toggleLockPosition() {
        settings.setLocksPosition(!settings.locksPosition)
    }

    @objc private func toggleLockSize() {
        settings.setLocksSize(!settings.locksSize)
    }

    @objc private func resetWidgetPosition() {
        host?.resetWidgetPosition()
    }

    @objc private func resetWidgetSize() {
        host?.resetWidgetSize()
    }

    @objc private func selectClosedSessionRetention(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else {
            return
        }
        settings.setClosedSessionRetention(ClosedSessionRetention(seconds: seconds))
    }

    @objc private func selectTranscriptPollInterval(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else {
            return
        }
        settings.setTranscriptPollInterval(seconds > 0 ? seconds : nil)
    }

    @objc private func quit() {
        host?.quit()
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        @objc private func toggleRawHookCapture() {
            host?.toggleRawHookCapture()
        }

        /// Deliberately its own action, and its own menu line.
        ///
        /// The recording switch limits how long payloads are written; nothing limited how
        /// long they stayed. A capture that stopped in the morning still held that morning's
        /// paths and shell commands at midnight, and the app offered no way to remove them.
        /// Merging this into the stop would be worse — stopping is what a person does in
        /// order to read what they recorded.
        @objc private func deleteRawHookRecordings() {
            guard let host else {
                return
            }
            host.deleteRawHookRecordings()
            refreshRawHookCapture(host: host)
        }
    #endif
}
