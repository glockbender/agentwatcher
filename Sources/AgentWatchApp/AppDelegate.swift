import AgentWatchCore
import AgentWatchIngress
import AgentWatchSender
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var widgetMenuItem: NSMenuItem?
    private var debugMenuItem: NSMenuItem?
    #if AGENT_WATCH_DEBUG_CAPTURE
        private var rawCaptureMenuItem: NSMenuItem?
        private var deleteRecordingsMenuItem: NSMenuItem?
    #endif
    private var lockPositionMenuItem: NSMenuItem?
    private var lockSizeMenuItem: NSMenuItem?
    private var sessionTopicMenuItem: NSMenuItem?
    private var updateOnLaunchMenuItem: NSMenuItem?
    private var closedSessionMenuItems: [NSMenuItem] = []
    private var transcriptMenuItems: [NSMenuItem] = []
    private let installer = ToolingInstaller()
    /// What the widget says instead of "No active sessions", as last read from the agents'
    /// own configuration files. Read at four moments, shown on every redraw.
    private var widgetComplaint: String?
    private var transcriptSummaryMenuItem: NSMenuItem?
    private let singleInstanceCoordinator: SingleInstanceCoordinator
    private let backgroundStore: WidgetBackgroundStore
    private let settings: WidgetSettingsStore
    private let frameStore: HUDFrameStore
    private let lampSchemes: LampSchemeStore
    private let preferences: PreferenceFile
    private let updater: AppUpdater
    private let heard = AgentHeardStore()
    private let history = SessionHistoryStore()
    private lazy var tooling: ToolingCoordinator = {
        let coordinator = ToolingCoordinator(installer: installer, heard: heard)
        coordinator.onLog = { [weak self] message in
            self?.recordDebug(message)
        }
        // One change, everything that shows it. The widget's complaint and the window that
        // describes the same installation used to be refreshed by whoever remembered to.
        coordinator.onChange = { [weak self] in
            self?.refreshToolingComplaint()
            self?.toolingController.rebuild()
        }
        return coordinator
    }()
    private lazy var toolingController = ToolingWindowController(
        facts: { [weak self] in
            self?.tooling.facts ?? ToolingWindowFacts.unavailable
        },
        act: { [weak self] press in
            self?.tooling.press(press)
        }
    )

    private lazy var supervisor: SessionSupervisor = SessionSupervisor(
        settings: settings,
        heard: heard,
        history: history,
        onChange: { [weak self] sessions, usageLimits in
            // Re-read before the widget is told, not after: the complaint travels with the
            // sessions now, so reading it afterwards would draw this report with the previous
            // answer. Only with no rows, which is the only time the complaint is on screen —
            // and the one time it can be stale, because `unheard` becomes `arrived` the
            // moment an event lands and nothing else here would notice.
            if sessions.isEmpty {
                self?.readToolingComplaint()
            }
            self?.renderWidget(sessions: sessions, usageLimits: usageLimits)
        },
        onNotableEvent: { [weak self] message in
            self?.recordDebug(message)
        }
    )
    private lazy var hudController: HUDPanelController = HUDPanelController(
        reach: { [weak self] snapshot in
            self?.supervisor.reach(for: snapshot) ?? .nowhere
        },
        focus: { [weak self] snapshot in
            self?.supervisor.focus(snapshot)
        },
        remove: { [weak self] snapshot in
            self?.supervisor.remove(snapshot)
        },
        background: backgroundStore.selected,
        lampScheme: lampSchemes.scheme,
        backgroundOpacity: backgroundStore.opacity,
        style: WidgetStyle(scale: settings.scale),
        frameStore: frameStore,
        settings: settings
    )
    private lazy var settingsWindow: WidgetSettingsWindowController = WidgetSettingsWindowController(
        backgroundStore: backgroundStore,
        lampSchemes: lampSchemes,
        settings: settings
    )
    private let debugLog = EventDebugLog()
    private lazy var debugController = EventDebugWindowController(initialEntries: debugLog.recentEntries())
    private lazy var ingress = HookIngressController(
        socketURL: { [singleInstanceCoordinator] in singleInstanceCoordinator.socketURL() },
        ingest: { [weak self] request in self?.supervisor.ingest(request) },
        reveal: { [weak self] in self?.revealExistingInstance() },
        log: { [weak self] message in self?.recordDebug(message) }
    )

    /// - Parameter preferences: the one settings file, shared by every store that reads it.
    ///   Two of these over one file would each keep a copy the other's writes never reach.
    init(
        singleInstanceCoordinator: SingleInstanceCoordinator,
        preferences: PreferenceFile = PreferenceFile()
    ) {
        self.singleInstanceCoordinator = singleInstanceCoordinator
        self.preferences = preferences
        self.updater = AppUpdater(preferences: preferences)
        backgroundStore = WidgetBackgroundStore(preferences: preferences)
        settings = WidgetSettingsStore(preferences: preferences)
        frameStore = HUDFrameStore(preferences: preferences)
        lampSchemes = LampSchemeStore(preferences: preferences)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wired here rather than at construction: the collaborators it reaches are built
        // lazily, and a write during start-up would otherwise build them out of order.
        settings.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        backgroundStore.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        lampSchemes.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        // Before anything reads a setting: a fresh install gets the whole configuration
        // written out, and a version that adds one fills in that key alone.
        let owners: [PreferenceDefaults] = [backgroundStore, settings, frameStore, lampSchemes, updater]
        var everyDefault: [String: JSONValue] = [:]
        for owner in owners {
            everyDefault.merge(owner.defaultValues) { existing, _ in existing }
        }
        preferences.seed(everyDefault)
        // Said out loud, because the alternative is a person's settings apparently reset for
        // no reason. The seeding above is the write that moves the old file aside.
        if let kept = preferences.unreadableFileKeptAt {
            recordDebug("Settings · the settings file could not be read; kept as \(kept.lastPathComponent)")
        }
        configureStatusItem()
        // Claimed at every launch, not only at install time. Hooks name the link, so the link
        // has to name a file that exists — and the copy that just started is the one that
        // certainly does, however the previous holder's build directory ended up.
        tooling.refreshSenderLink()
        // Before the widget is shown, so a first launch with nothing installed explains
        // itself in its first frame rather than after the first menu is opened.
        refreshToolingComplaint()
        hudController.show()
        // Restoring before listening, so the sessions of the last launch keep the row order
        // and the project names they had. An event that arrives first is still the live truth
        // and a memory never overwrites it — but it would come in as a brand new session.
        supervisor.start()
        ingress.start()
        updater.checkAfterLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ingress.stop()
        supervisor.stop()
        debugController.close()
        hudController.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc private func toggleHUD() {
        hudController.toggle()
    }

    @objc private func highlightHUD() {
        hudController.highlight()
    }

    @objc private func showSettings() {
        settingsWindow.present()
    }

    func revealExistingInstance() {
        hudController.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func toggleDebug() {
        debugController.toggle()
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        @objc private func toggleRawHookCapture() {
            if DebugHookCaptureControl.isEnabled() {
                DebugHookCaptureControl.disable()
            } else {
                _ = DebugHookCaptureControl.enable()
            }
        }

        /// Deliberately its own action, and its own menu line.
        ///
        /// The recording switch limits how long payloads are written; nothing limited how
        /// long they stayed. A capture that stopped in the morning still held that morning's
        /// paths and shell commands at midnight, and the app offered no way to remove them.
        /// Merging this into the stop would be worse — stopping is what a person does in
        /// order to read what they recorded.
        @objc private func deleteRawHookRecordings() {
            let bytes = DebugHookCaptureControl.recordedByteCount()
            DebugHookCaptureControl.deleteRecordings()
            recordDebug(
                "Deleted \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                    + " of recorded hook payloads")
            updateRawHookCaptureMenuItem()
        }
    #endif

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(
            systemSymbolName: "circle.grid.2x2.fill",
            accessibilityDescription: "Agent Watch"
        )
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Agent Watch"

        let menu = NSMenu()
        menu.delegate = self
        let toggleItem = NSMenuItem(
            title: "Show Widget",
            action: #selector(toggleHUD),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        widgetMenuItem = toggleItem
        let highlightItem = NSMenuItem(
            title: "Highlight Widget",
            action: #selector(highlightHUD),
            keyEquivalent: ""
        )
        highlightItem.target = self
        menu.addItem(highlightItem)
        // No key equivalent. This application is an accessory and is never the active one,
        // so a shortcut printed beside a status-item menu line would answer nothing anywhere
        // but inside the open menu — a promise the menu cannot keep.
        let settingsItem = NSMenuItem(
            title: "Widget Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(makeBehaviorMenuItem())
        let debugItem = NSMenuItem(
            title: "Show Event Debug",
            action: #selector(toggleDebug),
            keyEquivalent: ""
        )
        debugItem.target = self
        menu.addItem(debugItem)
        debugMenuItem = debugItem
        menu.addItem(makeToolingMenuItem())
        menu.addItem(makeTranscriptMenuItem())
        menu.addItem(makeUpdateMenuItem())
        #if AGENT_WATCH_DEBUG_CAPTURE
            let rawCaptureItem = NSMenuItem(
                title: "Record Raw Hook Payloads for 30 Minutes",
                action: #selector(toggleRawHookCapture),
                keyEquivalent: ""
            )
            rawCaptureItem.target = self
            rawCaptureItem.toolTip = "Debug only: saves original hook payloads locally for a limited time"
            menu.addItem(rawCaptureItem)
            rawCaptureMenuItem = rawCaptureItem
            let deleteRecordingsItem = NSMenuItem(
                title: "Delete Recorded Payloads",
                action: #selector(deleteRawHookRecordings),
                keyEquivalent: ""
            )
            deleteRecordingsItem.target = self
            menu.addItem(deleteRecordingsItem)
            deleteRecordingsMenuItem = deleteRecordingsItem
        #endif
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Agent Watch", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Opening the menu is a person asking what is going on, which is the moment an agent
        // the app has never heard from is most worth finding. It costs about a millisecond
        // and saves a timer: see `SessionSupervisor.discoverAgentProcesses`.
        supervisor.discoverAgentProcesses()
        widgetMenuItem?.title = hudController.window?.isVisible == true ? "Hide Widget" : "Show Widget"
        debugMenuItem?.title = debugController.isVisible ? "Hide Event Debug" : "Show Event Debug"
        #if AGENT_WATCH_DEBUG_CAPTURE
            updateRawHookCaptureMenuItem()
        #endif
        lockPositionMenuItem?.state = settings.locksPosition ? .on : .off
        lockSizeMenuItem?.state = settings.locksSize ? .on : .off
        sessionTopicMenuItem?.state = settings.showsSessionTopic ? .on : .off
        updateOnLaunchMenuItem?.state = updater.checksOnLaunch ? .on : .off
        updateClosedSessionMenuSelection()
        updateTranscriptMenu()
        // The files belong to other programs and other people, so what the widget complains
        // about is read again rather than remembered from the last time this app looked.
        refreshToolingComplaint()
    }

    private func makeBehaviorMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Widget Behavior", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Widget Behavior")

        let lockPosition = NSMenuItem(
            title: "Lock Position",
            action: #selector(toggleLockPosition),
            keyEquivalent: ""
        )
        lockPosition.target = self
        lockPosition.toolTip = "Stops an accidental drag from moving the widget"
        submenu.addItem(lockPosition)
        lockPositionMenuItem = lockPosition

        let lockSize = NSMenuItem(title: "Lock Size", action: #selector(toggleLockSize), keyEquivalent: "")
        lockSize.target = self
        lockSize.toolTip = "Stops an accidental drag on an edge from resizing the widget"
        submenu.addItem(lockSize)
        lockSizeMenuItem = lockSize

        let resetPosition = NSMenuItem(
            title: "Reset Widget Position",
            action: #selector(resetWidgetPosition),
            keyEquivalent: ""
        )
        resetPosition.target = self
        resetPosition.toolTip = "Brings the widget back to the middle of the main screen"
        submenu.addItem(resetPosition)

        let resetSize = NSMenuItem(title: "Reset Widget Size", action: #selector(resetWidgetSize), keyEquivalent: "")
        resetSize.target = self
        resetSize.toolTip = "Lets the widget size itself to the number of sessions again"
        submenu.addItem(resetSize)

        submenu.addItem(.separator())
        submenu.addItem(makeClosedSessionMenuItem())
        submenu.addItem(.separator())

        let sessionTopic = NSMenuItem(
            title: "Show Session Topic",
            action: #selector(toggleSessionTopic),
            keyEquivalent: ""
        )
        sessionTopic.target = self
        // Deliberately says "show": the sender resolves the topic either way, so the app
        // can only stop displaying it, not stop it from being read.
        sessionTopic.toolTip = "Shows each session's own name next to its status"
        submenu.addItem(sessionTopic)
        sessionTopicMenuItem = sessionTopic

        item.submenu = submenu
        return item
    }

    /// The second source of truth, and the only setting that can turn it off.
    ///
    /// Its own menu rather than a line in `Widget Behavior`, because it is not about the
    /// widget: it decides how much the app can know about a session, and it is where a
    /// failure to read is reported.
    /// Where a person can see how far Agent Watch got into their tooling, and change it.
    ///
    /// Every line is both the state and the switch: not installed puts it in, installed takes
    /// it out. Rebuilt on each open rather than kept in step, because what it describes lives
    /// in files other programs and other people also write.
    private func makeToolingMenuItem() -> NSMenuItem {
        // One line and a window behind it. This used to be a submenu whose every line was
        // both the state and the switch, and the answer stopped fitting on a menu line once
        // it had to carry the sender's path and the step Codex still needs from a person.
        let item = NSMenuItem(title: "Tooling…", action: #selector(showTooling), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showTooling() {
        toolingController.present()
    }

    /// The version this copy is, and the two decisions about newer ones.
    ///
    /// A submenu rather than a line, because the version belongs in the interface somewhere:
    /// it is the first thing anybody reporting a problem is asked for, and an app with no
    /// window of its own has nowhere else to put it.
    private func makeUpdateMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let version = NSMenuItem(
            title: updater.ownVersion.map { "Agent Watch \($0)" } ?? "Agent Watch (development build)",
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false
        submenu.addItem(version)
        submenu.addItem(.separator())
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        submenu.addItem(check)
        let onLaunch = NSMenuItem(
            title: "Check on Launch",
            action: #selector(toggleUpdateCheckOnLaunch),
            keyEquivalent: ""
        )
        onLaunch.target = self
        submenu.addItem(onLaunch)
        updateOnLaunchMenuItem = onLaunch
        item.submenu = submenu
        return item
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func toggleUpdateCheckOnLaunch() {
        updater.checksOnLaunch.toggle()
    }

    /// Keeps the widget's own complaint in step with what is actually installed.
    ///
    /// Cheap — it reads two small files — and it runs where the widget is redrawn rather than
    /// on a timer, so the message cannot outlive the problem that produced it: at launch, when
    /// the tooling menu opens, after a tooling change, and whenever the widget empties, which
    /// is when this message is the thing a person is looking at.
    ///
    /// Reading and showing are two steps because they happen at different rates: the files
    /// are read at those four moments, while the widget is drawn on every event. What is read
    /// here is kept in `toolingComplaint` and travels with the next state.
    private func refreshToolingComplaint() {
        readToolingComplaint()
        renderWidget()
    }

    private func readToolingComplaint() {
        widgetComplaint = tooling.complaint()
    }

    /// Hands the widget everything it shows, in one value.
    ///
    /// Sessions come from the supervisor unless a report is being passed through — during
    /// that report the supervisor is mid-publish, and asking it again would re-derive the
    /// same list it is already handing over.
    private func renderWidget(
        sessions: [SessionSnapshot]? = nil,
        usageLimits: [AgentUsageLimits]? = nil
    ) {
        hudController.render(
            WidgetState(
                sessions: sessions ?? supervisor.sessions,
                usageLimits: usageLimits ?? supervisor.usageLimits,
                complaint: widgetComplaint
            )
        )
    }

    private func makeTranscriptMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Read Session Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Read Session Transcripts")

        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        submenu.addItem(summary)
        transcriptSummaryMenuItem = summary
        submenu.addItem(.separator())

        transcriptMenuItems = WidgetSettingsStore.offeredTranscriptPollIntervals.map { interval in
            let entry = NSMenuItem(
                title: transcriptIntervalMenuTitle(interval: interval),
                action: #selector(selectTranscriptPollInterval(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            // Zero stands for off. An absent `representedObject` cannot be told apart from
            // one that was never set, and "off" has to be a choice like the others.
            entry.representedObject = NSNumber(value: interval ?? 0)
            submenu.addItem(entry)
            return entry
        }

        item.submenu = submenu
        return item
    }

    @objc private func selectTranscriptPollInterval(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else {
            return
        }
        settings.setTranscriptPollInterval(seconds > 0 ? seconds : nil)
    }

    private func updateTranscriptMenu() {
        let selected = settings.transcriptPollInterval
        for item in transcriptMenuItems {
            let seconds = (item.representedObject as? NSNumber)?.doubleValue ?? 0
            item.state = (seconds > 0 ? seconds : nil) == selected ? .on : .off
        }
        transcriptSummaryMenuItem?.title = transcriptMenuSummary(
            interval: selected,
            isReading: supervisor.isReadingTranscripts,
            faultedSessionCount: supervisor.faultedSessionCount
        )
    }

    private func makeClosedSessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Closed Sessions", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Closed Sessions")
        closedSessionMenuItems = WidgetSettingsStore.offeredClosedSessionRetentions.map { retention in
            let entry = NSMenuItem(
                title: Self.title(for: retention),
                action: #selector(selectClosedSessionRetention(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = retention.seconds
            submenu.addItem(entry)
            return entry
        }
        item.submenu = submenu
        return item
    }

    private static func title(for retention: ClosedSessionRetention) -> String {
        switch retention {
        case .manual:
            "Keep until dismissed"
        case let .after(seconds):
            seconds < 120
                ? "Remove after \(Int(seconds)) seconds"
                : "Remove after \(Int(seconds / 60)) minutes"
        }
    }

    private func updateClosedSessionMenuSelection() {
        let selected = settings.closedSessionRetention.seconds
        for item in closedSessionMenuItems {
            let seconds = item.representedObject as? TimeInterval
            item.state = seconds == selected ? .on : .off
        }
    }

    @objc private func toggleLockPosition() {
        settings.setLocksPosition(!settings.locksPosition)
    }

    @objc private func toggleLockSize() {
        settings.setLocksSize(!settings.locksSize)
    }

    @objc private func resetWidgetPosition() {
        hudController.resetPosition()
    }

    @objc private func resetWidgetSize() {
        hudController.resetSize()
    }

    @objc private func toggleSessionTopic() {
        settings.setShowsSessionTopic(!settings.showsSessionTopic)
    }

    @objc private func selectClosedSessionRetention(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else {
            return
        }
        settings.setClosedSessionRetention(ClosedSessionRetention(seconds: seconds))
    }

    /// Who has to be told when a setting changes, written once.
    ///
    /// Nothing here is new — each line used to sit in the menu action that made the write.
    /// The problem was that the list was knowledge every writer had to carry, and a writer
    /// who forgot one produced a setting that appeared not to work and then fixed itself
    /// minutes later. That has already happened once, to the topic toggle.
    private func settingChanged(_ setting: WidgetSetting) {
        switch setting {
        case .interactionLocks:
            hudController.refreshInteractionLocks()
        case .sessionTopic:
            // Not `supervisor.publish()`: that reports the same sessions, and the widget
            // skips a report that changes nothing so the row under the pointer survives.
            hudController.refreshSettings()
        case .closedSessionRetention:
            updateClosedSessionMenuSelection()
            supervisor.runMaintenance()
        case .transcriptPollInterval:
            supervisor.transcriptSettingsChanged()
            updateTranscriptMenu()
        case .background:
            hudController.setBackground(backgroundStore.selected)
        case .lampScheme:
            hudController.setLampScheme(lampSchemes.scheme)
        case .backgroundOpacity:
            // Read back rather than carrying the value in the notification: the store clamps
            // to a non-zero floor, and a control that passed its own raw value would let the
            // live widget reach full invisibility while the saved setting did not — so the
            // widget would reappear on the next launch.
            hudController.setBackgroundOpacity(backgroundStore.opacity)
        case .scale:
            // Read back for the reason the opacity gives above: the store clamps, and a
            // control that passed its own raw value would draw the widget at a size the saved
            // setting does not hold — so the next launch would show a different widget.
            hudController.setScale(settings.scale)
        }
    }

    private func recordDebug(_ message: String) {
        let entry = debugLog.makeEntry(for: message)
        debugLog.append(entry)
        debugController.append(entry)
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        private func updateRawHookCaptureMenuItem(now: Date = .now) {
            // Shown only when there is something to delete, so its presence is itself the
            // answer to "is any of this still on disk", which nothing used to state.
            if let deleteItem = deleteRecordingsMenuItem {
                let bytes = DebugHookCaptureControl.recordedByteCount()
                deleteItem.isHidden = bytes == 0
                deleteItem.title =
                    "Delete Recorded Payloads"
                    + " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            }
            guard let item = rawCaptureMenuItem else {
                return
            }
            guard let expiry = DebugHookCaptureControl.expiry(), expiry > now else {
                item.title = "Record Raw Hook Payloads for 30 Minutes"
                item.state = .off
                return
            }
            let remainingMinutes = max(1, Int(ceil(expiry.timeIntervalSince(now) / 60)))
            item.title = "Stop Recording Raw Hook Payloads (\(remainingMinutes)m)"
            item.state = .on
        }
    #endif
}
