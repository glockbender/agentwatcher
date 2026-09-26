import AgentWatchCore
import AgentWatchIngress
import AgentWatchSender
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenu?
    /// The counts drawn into the status item, or `nil` while it shows the plain app glyph.
    private var menuBarIconView: MenuBarIconView?
    /// What the icon is currently showing. Kept so that the drawing follows a change rather
    /// than every report: most of what happens to a session moves none of these four numbers.
    private var menuBarCounts = SessionAttentionCounts.empty
    private let installer = ToolingInstaller()
    /// What the widget says instead of "No active sessions", as last read from the agents'
    /// own configuration files. Read at four moments, shown on every redraw.
    private var widgetComplaint: String?
    private let singleInstanceCoordinator: SingleInstanceCoordinator
    private let backgroundStore: WidgetBackgroundStore
    private let settings: WidgetSettingsStore
    private let frameStore: HUDFrameStore
    private let lampSchemes: LampSchemeStore
    private let rowLayouts: RowLayoutStore
    private let preferences: PreferenceFile
    private let updater: AppUpdater
    private let heard = AgentHeardStore()
    /// Keeps the combination that hides and shows the widget agreeing with the setting.
    private lazy var shortcuts = WidgetShortcutController(
        settings: settings,
        registrar: GlobalShortcutRegistrar(),
        onToggle: { [weak self] in
            self?.hudController.toggle()
        }
    )
    private let history = SessionHistoryStore()
    private lazy var orderBook = SessionOrderBook(settings: settings)
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
    private lazy var hudController: HUDPanelController = {
        let controller = HUDPanelController(
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
            settings: settings,
            rowLayouts: rowLayouts
        )
        // The order the menu shows too — see `SessionOrderBook`.
        controller.order = { [orderBook] sessions, now in
            orderBook.order(sessions, now: now)
        }
        return controller
    }()
    private lazy var settingsWindow: WidgetSettingsWindowController = WidgetSettingsWindowController(
        backgroundStore: backgroundStore,
        lampSchemes: lampSchemes,
        settings: settings,
        rowLayouts: rowLayouts,
        shortcuts: shortcuts
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
        rowLayouts = RowLayoutStore(preferences: preferences)
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
        rowLayouts.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        // Before anything reads a setting: a fresh install gets the whole configuration
        // written out, and a version that adds one fills in that key alone.
        let owners: [PreferenceDefaults] = [
            backgroundStore, settings, frameStore, lampSchemes, rowLayouts, updater,
        ]
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
        // After the widget is on screen: the shortcut's whole job is to take it away again.
        applyShortcut()
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

    func revealExistingInstance() {
        hudController.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = StatusMenu(settings: settings, version: updater.ownVersion, host: self)
        item.menu = menu.menu
        statusMenu = menu
        statusItem = item
        applyMenuBarIcon()
    }

    /// Puts the status item into whichever of its two states the setting asks for.
    ///
    /// The plain state is exactly what shipped before the counts existed: a template glyph on
    /// a `squareLength` item, 22 pt. That length matters — the same glyph on a
    /// `variableLength` item measures 32 pt, so an item left variable would be 10 pt wider
    /// than before while showing strictly less.
    private func applyMenuBarIcon() {
        guard let item = statusItem, let button = item.button else {
            return
        }
        guard settings.showsMenuBarCounts else {
            showPlainStatusGlyph(on: item)
            return
        }

        let view = menuBarIconView ?? makeMenuBarIconView()
        guard view.show(MenuBarIconCell.grid(for: menuBarCounts)) else {
            // A symbol the running system does not have. Fail-open, like every other reading
            // of something this app does not own.
            showPlainStatusGlyph(on: item)
            return
        }
        menuBarIconView = view
        button.image = nil
        if view.superview !== button {
            button.addSubview(view)
        }
        if let width = view.drawnWidth {
            item.length = width + MenuBarIconMetrics.itemPadding
        }
        view.fill(button)
        updateStatusItemWording()
    }

    private func makeMenuBarIconView() -> MenuBarIconView {
        let view = MenuBarIconView()
        // The view draws itself and therefore knows its width first; the item's length is not
        // its to set.
        view.onWidthChange = { [weak self] width in
            self?.statusItem?.length = width + MenuBarIconMetrics.itemPadding
        }
        return view
    }

    private func showPlainStatusGlyph(on item: NSStatusItem) {
        menuBarIconView?.removeFromSuperview()
        menuBarIconView = nil
        let image = NSImage(
            systemSymbolName: "circle.grid.2x2.fill",
            accessibilityDescription: "Agent Watch"
        )
        image?.isTemplate = true
        item.length = NSStatusItem.squareLength
        item.button?.image = image
        item.button?.toolTip = "Agent Watch"
        item.button?.setAccessibilityLabel("Agent Watch")
    }

    /// The tooltip and the accessibility label say what the icon says, in the menu's words.
    private func updateStatusItemWording() {
        let line = MenuBarSummaryText.line(for: menuBarCounts)
        statusItem?.button?.toolTip = "Agent Watch — \(line)"
        statusItem?.button?.setAccessibilityLabel("Agent Watch. \(line)")
    }

    /// Redraws the icon, and only when one of its four numbers has moved.
    private func updateMenuBarIcon(sessions: [SessionSnapshot]) {
        let counts = SessionAttentionCounts(sessions: sessions)
        guard counts != menuBarCounts else {
            return
        }
        menuBarCounts = counts
        menuBarIconView?.show(MenuBarIconCell.grid(for: counts))
        updateStatusItemWording()
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
        let shown = sessions ?? supervisor.sessions
        hudController.render(
            WidgetState(
                sessions: shown,
                usageLimits: usageLimits ?? supervisor.usageLimits,
                complaint: widgetComplaint
            )
        )
        // The same list, and the same moment. A second source of sessions for the status item
        // would be a second answer to the question this app exists to answer once.
        updateMenuBarIcon(sessions: shown)
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
        case .rowLayout:
            // Not `supervisor.publish()`: that reports the same sessions, and the widget
            // skips a report that changes nothing so the row under the pointer survives.
            hudController.refreshSettings()
        case .closedSessionRetention:
            statusMenu?.refresh()
            supervisor.runMaintenance()
        case .transcriptPollInterval:
            supervisor.transcriptSettingsChanged()
            statusMenu?.refresh()
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
        case .toggleShortcut:
            applyShortcut()
        case .menuBarCounts:
            applyMenuBarIcon()
        case .sessionOrder:
            // A new order is a new set of rows, and the menu's lines follow it as well.
            hudController.refreshSettings()
            statusMenu?.refreshSessions()
        case .menuSessions:
            // The menu refreshes itself after its own choice; this is for a write from anywhere
            // else, which would otherwise show only on the next opening.
            statusMenu?.refreshSessions()
        }
    }

    /// Registers the combination and writes down what came of it.
    ///
    /// Said out loud because the failure is otherwise invisible: the menu deliberately prints
    /// nothing when the combination does not work, and the settings window is a place a person
    /// has to already suspect something before they open it.
    private func applyShortcut() {
        shortcuts.apply()
        recordDebug("Shortcut · \(shortcutStatusLine(shortcuts.status))")
    }

    private func recordDebug(_ message: String) {
        let entry = debugLog.makeEntry(for: message)
        debugLog.append(entry)
        debugController.append(entry)
    }
}

extension AppDelegate: StatusMenuHost {
    var attentionCounts: SessionAttentionCounts {
        menuBarCounts
    }

    var isWidgetVisible: Bool {
        hudController.window?.isVisible == true
    }

    var isEventDebugVisible: Bool {
        debugController.isVisible
    }

    var checksForUpdatesOnLaunch: Bool {
        get { updater.checksOnLaunch }
        set { updater.checksOnLaunch = newValue }
    }

    var isReadingTranscripts: Bool {
        supervisor.isReadingTranscripts
    }

    var transcriptFaultedSessionCount: Int {
        supervisor.faultedSessionCount
    }

    var sessions: [SessionSnapshot] {
        orderBook.order(supervisor.sessions, now: .now)
    }

    func reach(for snapshot: SessionSnapshot) -> SessionReach {
        supervisor.reach(for: snapshot)
    }

    /// Looked up at the click, not taken from when the menu opened: the session may have moved
    /// on, or gone, while the menu stood open.
    func focusSession(id: String) {
        guard let snapshot = supervisor.sessions.first(where: { $0.id == id }) else {
            recordDebug("Menu · the session was gone before the click; nothing to bring forward")
            return
        }
        supervisor.focus(snapshot)
    }

    func menuWillOpen() {
        // Opening the menu is a person asking what is going on, which is the moment an agent
        // the app has never heard from is most worth finding. It costs about a millisecond
        // and saves a timer: see `SessionSupervisor.discoverAgentProcesses`.
        supervisor.discoverAgentProcesses()
        // The files belong to other programs and other people, so what the widget complains
        // about is read again rather than remembered from the last time this app looked.
        refreshToolingComplaint()
    }

    func showShortcut(on item: NSMenuItem) {
        shortcuts.showShortcut(on: item)
    }

    func toggleWidget() {
        hudController.toggle()
    }

    func highlightWidget() {
        hudController.highlight()
    }

    func showWidgetSettings() {
        settingsWindow.present()
    }

    func showTooling() {
        toolingController.present()
    }

    func toggleEventDebug() {
        debugController.toggle()
    }

    func checkForUpdates() {
        updater.checkNow()
    }

    func resetWidgetPosition() {
        hudController.resetPosition()
    }

    func resetWidgetSize() {
        hudController.resetSize()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        var rawCaptureExpiry: Date? {
            DebugHookCaptureControl.expiry()
        }

        var recordedPayloadBytes: Int {
            DebugHookCaptureControl.recordedByteCount()
        }

        func toggleRawHookCapture() {
            if DebugHookCaptureControl.isEnabled() {
                DebugHookCaptureControl.disable()
            } else {
                _ = DebugHookCaptureControl.enable()
            }
        }

        func deleteRawHookRecordings() {
            let bytes = DebugHookCaptureControl.recordedByteCount()
            DebugHookCaptureControl.deleteRecordings()
            recordDebug(
                "Deleted \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                    + " of recorded hook payloads")
        }
    #endif
}
