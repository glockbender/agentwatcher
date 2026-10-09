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
    private let settings: WidgetSettingsStore
    private let frameStore: HUDFrameStore
    private let themes: ThemeStore
    private let rowLayouts: RowLayoutStore
    private let preferences: PreferenceFile
    private let updater: AppUpdater
    private let heard = AgentHeardStore()
    /// Keeps the combination that hides and shows the widget agreeing with the setting.
    private lazy var shortcuts = WidgetShortcutController(
        settings: settings,
        registrar: GlobalShortcutRegistrar(),
        onToggle: { [weak self] in
            self?.toggleWidget()
        }
    )
    private let history = SessionHistoryStore()
    private lazy var orderBook = SessionOrderBook(settings: settings)
    private lazy var tooling: ToolingCoordinator = {
        let coordinator = ToolingCoordinator(
            installer: installer,
            heard: heard,
            extraFolders: { [weak self] in self?.settings.extraAgentFolders ?? [:] },
            setExtraFolders: { [weak self] source, paths in self?.settings.setExtraFolders(paths, for: source) },
            chooseFolder: { [weak self] source in self?.chooseAgentFolder(for: source) }
        )
        coordinator.onLog = { [weak self] message in
            self?.recordDebug(message)
        }
        // One change, everything that shows it. The widget's complaint and the page that
        // describes the same installation used to be refreshed by whoever remembered to.
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            refreshToolingComplaint()
            // A page that is not on screen reads the disk when it next is.
            if settingsWindow.model.isShowingTooling {
                settingsWindow.model.tooling.reread()
            }
        }
        return coordinator
    }()

    private lazy var supervisor: SessionSupervisor = SessionSupervisor(
        settings: settings,
        extraAgentFolders: { [weak self] in self?.settings.extraAgentFolders ?? [:] },
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
                self?.supervisor.focus(snapshot) ?? .nothingRaised
            },
            remove: { [weak self] snapshot in
                self?.supervisor.remove(snapshot)
            },
            endAgent: { [weak self] sessionID in
                self?.supervisor.endAgent(ofSessionWithID: sessionID)
            },
            background: themes.textBackground,
            lampScheme: themes.look.lampScheme,
            backgroundOpacity: themes.look.widgetOpacity,
            style: WidgetStyle(scale: settings.scale),
            frameStore: frameStore,
            settings: settings,
            rowLayouts: rowLayouts
        )
        controller.openSetup = { [weak self] in
            self?.showSetupGuide()
        }
        // The order the menu shows too — see `SessionOrderBook`.
        controller.order = { [orderBook] sessions, now in
            orderBook.order(sessions, now: now)
        }
        return controller
    }()
    private lazy var settingsWindow: SettingsWindowController = SettingsWindowController(
        themes: themes,
        settings: settings,
        rowLayouts: rowLayouts,
        shortcuts: shortcuts,
        host: self,
        version: updater.ownVersion
    )
    private lazy var fullScreenDot = FullScreenDot()
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var themeChange = CoalescedWork { [weak self] in
        self?.applyTheme()
    }
    #if DEBUG
        private var themeDragProbe: ThemeDragProbe?
    #endif
    private let debugLog = EventDebugLog()
    private lazy var debugController = EventDebugWindowController(initialEntries: debugLog.recentEntries())
    private lazy var ingress = HookIngressController(
        socketURL: { [singleInstanceCoordinator] in singleInstanceCoordinator.socketURL() },
        ingest: { [weak self] request in
            guard let self else { return nil }
            let event = self.supervisor.ingest(request)
            if self.settingsWindow.model.isShowingTooling {
                self.settingsWindow.model.tooling.receivedEvents(self.tooling.receivedSources)
            }
            return event
        },
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
        settings = WidgetSettingsStore(preferences: preferences)
        frameStore = HUDFrameStore(preferences: preferences)
        themes = ThemeStore(
            preferences: preferences,
            folder: AgentWatchPaths.supportDirectory()?.appendingPathComponent("Themes", isDirectory: true)
        )
        rowLayouts = RowLayoutStore(preferences: preferences)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wired here rather than at construction: the collaborators it reaches are built
        // lazily, and a write during start-up would otherwise build them out of order.
        settings.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        themes.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if self?.themes.mode == .auto {
                    self?.settingChanged(.theme)
                }
            }
        }
        rowLayouts.onChange = { [weak self] setting in
            self?.settingChanged(setting)
        }
        // Before anything reads a setting: a fresh install gets the whole configuration
        // written out, and a version that adds one fills in that key alone.
        let owners: [PreferenceDefaults] = [
            settings, frameStore, themes, rowLayouts, updater,
        ]
        var everyDefault: [String: JSONValue] = [:]
        for owner in owners {
            everyDefault.merge(owner.defaultValues) { existing, _ in existing }
        }
        preferences.seed(everyDefault)
        ThemeInUse.look = themes.look
        ThemeInUse.timing = themes.theme.timing.clamped
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
        if settings.showsWidget {
            hudController.show()
        }
        // Restoring before listening, so the sessions of the last launch keep the row order
        // and the project names they had. An event that arrives first is still the live truth
        // and a memory never overwrites it — but it would come in as a brand new session.
        supervisor.start()
        ingress.start()
        // After the widget is on screen: the shortcut's whole job is to take it away again.
        applyShortcut()
        updater.checkAfterLaunch()
        #if DEBUG
            // The probes write settings as they draw — the mode, the order, the row — so they
            // run on a copy of the state only, never on a person's own.
            let probes = [
                "AGENT_WATCH_SETTINGS_SNAPSHOT", "AGENT_WATCH_WIDGET_SNAPSHOT", "AGENT_WATCH_THEME_DRAG_PROBE",
            ]
            let environment = ProcessInfo.processInfo.environment
            if probes.contains(where: { environment[$0] != nil }), environment["AGENT_WATCH_SUPPORT_DIR"] == nil {
                FileHandle.standardError.write(Data("a probe runs only with AGENT_WATCH_SUPPORT_DIR set\n".utf8))
                NSApplication.shared.terminate(nil)
                return
            }
            if let directory = ProcessInfo.processInfo.environment["AGENT_WATCH_SETTINGS_SNAPSHOT"] {
                settingsWindow.snapshot(into: URL(fileURLWithPath: directory)) {
                    NSApplication.shared.terminate(nil)
                }
            }
            if let directory = ProcessInfo.processInfo.environment["AGENT_WATCH_WIDGET_SNAPSHOT"] {
                snapshotWidget(into: URL(fileURLWithPath: directory))
            }
            if let file = ProcessInfo.processInfo.environment["AGENT_WATCH_THEME_DRAG_PROBE"] {
                themeDragProbe = ThemeDragProbe(window: settingsWindow, file: URL(fileURLWithPath: file))
                themeDragProbe?.start()
            }
        #endif
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
        settings.setShowsWidget(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = StatusMenu(settings: settings, host: self)
        item.menu = menu.menu
        statusMenu = menu
        statusItem = item
        applyMenuBarIcon()
    }

    /// Puts the status item into whichever of its styles the setting asks for.
    private func applyMenuBarIcon() {
        guard let item = statusItem, let button = item.button else {
            return
        }
        let view = menuBarIconView ?? makeMenuBarIconView()
        guard view.show(menuBarCells, as: settings.menuBarIconStyle) else {
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
        if let length = view.itemLength {
            item.length = length
        }
        view.fill(button)
        updateStatusItemWording()
    }

    /// The states the icon is set to show, with their counts.
    private var menuBarCells: [MenuBarIconCell] {
        MenuBarIconCell.cells(for: menuBarCounts, showing: settings.menuBarIconAttentions)
    }

    private func makeMenuBarIconView() -> MenuBarIconView {
        let view = MenuBarIconView()
        // The view draws itself and therefore knows its width first; the item's length is not
        // its to set.
        view.onLengthChange = { [weak self] length in
            self?.statusItem?.length = length
        }
        return view
    }

    /// What shipped before the counts existed, kept only for the grid's missing symbols: a
    /// template glyph on a `squareLength` item, 22 pt. That length matters — the same glyph on
    /// a `variableLength` item measures 32 pt, 10 pt wider for an icon that shows less.
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
    ///
    /// All four, not only the states shown: the tooltip below says every one of them. The
    /// view skips a drawing whose cells have not changed, so a number the icon does not show
    /// moves nothing on the bar.
    private func updateMenuBarIcon(sessions: [SessionSnapshot]) {
        let counts = SessionAttentionCounts(sessions: sessions)
        let phases = sessions.reduce(into: [SessionPhase: Int]()) { $0[$1.phase, default: 0] += 1 }
        let phasesMatter = ThemeInUse.look.isRedrawn(forPhases: phases, after: ThemeInUse.phases)
        ThemeInUse.phases = phases
        guard counts != menuBarCounts || phasesMatter else {
            return
        }
        menuBarCounts = counts
        fullScreenDot.show(counts, enabled: settings.showsFullScreenDot)
        menuBarIconView?.show(menuBarCells, as: settings.menuBarIconStyle)
        updateStatusItemWording()
        statusMenu?.refreshSummary()
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
        let shown = (sessions ?? supervisor.sessions).shown(includingHeadlessRuns: settings.showsHeadlessRuns)
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

    /// Who has to be told when a setting changes, written once rather than by every writer:
    /// a writer that forgot one would leave a setting that appears not to work and then fixes
    /// itself minutes later.
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
        case .theme:
            // Once per turn of the run loop, however many changes arrive in it (`CoalescedWork`).
            themeChange.request()
        case .scale:
            // Read back from the store, which clamps: a control that passed its own raw value
            // would draw the widget at a size the saved setting does not hold, and the next
            // launch would show a different widget.
            hudController.setScale(settings.scale)
        case .toggleShortcut:
            applyShortcut()
        case .menuBarIcon:
            applyMenuBarIcon()
            fullScreenDot.show(menuBarCounts, enabled: settings.showsFullScreenDot)
        case .sessionOrder:
            // A new order is a new set of rows, and the menu's lines follow it as well. Written
            // by the settings window, so nothing else refreshes them.
            hudController.refreshSettings()
            statusMenu?.refreshSessions()
        case .menuSessions:
            statusMenu?.refreshSessions()
        case .headlessRuns:
            renderWidget()
            statusMenu?.refreshSessions()
        case .agentFolders:
            // The rows of the Tooling page and the widget's complaint both count folders. The
            // sessions read the list where they use it, so nothing else needs a poke.
            refreshToolingComplaint()
            if settingsWindow.model.isShowingTooling {
                settingsWindow.model.tooling.reread()
            }
        }
    }

    /// Asks for a folder an agent is started with, beginning in the home folder and showing
    /// what is hidden there: every agent's folder is a dot-folder, which the panel otherwise
    /// leaves out.
    private func chooseAgentFolder(for source: AgentSource) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = AgentWatchPaths.homeDirectory()
        panel.prompt = "Add"
        panel.message =
            "Choose the folder \(AgentIcon.name(for: source)) is started with as "
            + "\(AgentFolders.variableName(for: source))."
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The theme in use, drawn everywhere it shows.
    ///
    /// Read back from the theme rather than carried in the notification: the look clamps
    /// opacity to a non-zero floor, and a control that passed its own raw value would let the
    /// live widget reach full invisibility while the saved theme did not.
    private func applyTheme() {
        let look = themes.look
        ThemeInUse.look = look
        ThemeInUse.timing = themes.theme.timing.clamped
        hudController.setAppearance(
            background: themes.textBackground, lampScheme: look.lampScheme, opacity: look.widgetOpacity)
        // Not the menu's lines: it reads them, marks included, each time it opens, and
        // building them asks the process tree about every broken session.
        menuBarIconView?.show(menuBarCells, as: settings.menuBarIconStyle)
        fullScreenDot.refresh()
        settingsWindow.refresh()
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

    #if DEBUG
        /// The widget over the real desktop, on glass in both modes from nearly clear to full
        /// colour, and on clear glass — the cases where glass is hardest to read.
        private func snapshotWidget(into directory: URL) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cases: [(ThemeMode, CGFloat, WidgetMaterial)] = [
                (.dark, 0.05, .glass), (.dark, 0.5, .glass), (.dark, 1, .glass),
                (.light, 0.05, .glass), (.light, 1, .glass), (.dark, 1, .clearGlass),
            ]
            func run(_ index: Int) {
                guard index < cases.count else {
                    NSApplication.shared.terminate(nil)
                    return
                }
                let (mode, opacity, material) = cases[index]
                themes.select(mode)
                // Now rather than on the next turn, which would put the theme's own material
                // back over the one this picture is of.
                themeChange.runIfPending()
                ThemeInUse.look.widgetMaterial = material
                let look = themes.look
                hudController.setAppearance(
                    background: material.drawn.textBackground(for: look, dark: themes.isDark),
                    lampScheme: look.lampScheme, opacity: opacity)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    if let window = hudController.window, let screen = NSScreen.screens.first {
                        let frame = window.frame.insetBy(dx: -24, dy: -24)
                        let rect = CGRect(
                            x: frame.minX, y: screen.frame.height - frame.maxY, width: frame.width, height: frame.height
                        )
                        guard let png = captureWindow(window.windowNumber, withDesktop: true, in: rect) else {
                            run(index + 1)
                            return
                        }
                        let name = "\(index)-\(material.rawValue)-\(mode.rawValue)-\(Int(opacity * 100)).png"
                        try? png.write(to: directory.appendingPathComponent(name))
                    }
                    run(index + 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { run(0) }
        }
    #endif

    private func recordDebug(_ message: String) {
        let entry = debugLog.makeEntry(for: message)
        debugLog.append(entry)
        debugController.append(entry)
    }
}

extension AppDelegate: StatusMenuHost, SettingsHost {
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
        orderBook.order(supervisor.sessions.shown(includingHeadlessRuns: settings.showsHeadlessRuns), now: .now)
    }

    func reach(for snapshot: SessionSnapshot) -> SessionReach {
        supervisor.reach(for: snapshot)
    }

    /// Looked up at the click, not taken from when the menu opened: the session may have moved
    /// on, or gone, while the menu stood open.
    func focusSession(id: String) -> SessionClick {
        supervisor.focusSession(id: id)
    }

    func endAgent(ofSessionWithID id: String) {
        supervisor.endAgent(ofSessionWithID: id)
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

    /// Showing the widget also flashes it, so it is found wherever it sits. The menu and the
    /// shortcut both come here, and the settings window's switch follows either.
    func toggleWidget() {
        hudController.toggle()
        settings.setShowsWidget(isWidgetVisible)
        if isWidgetVisible {
            hudController.highlight()
        }
        settingsWindow.refresh()
    }

    func showWidgetSettings() {
        settingsWindow.present()
    }

    /// `Connect Agent →` in the empty widget: the settings window, on the Tooling page, at the
    /// guide's first step.
    func showSetupGuide() {
        settingsWindow.model.tooling.startSetup()
        settingsWindow.model.go(.tooling)
        settingsWindow.present()
    }

    func toolingFacts() -> ToolingFacts {
        var facts = tooling.facts
        if case let .active(shortcut) = shortcuts.status {
            facts.widgetShortcut = shortcut.displayed
        }
        return facts
    }

    func pressTooling(_ press: ToolingPress) {
        tooling.press(press)
    }

    func forgetToolingError() {
        tooling.forgetLastError()
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
