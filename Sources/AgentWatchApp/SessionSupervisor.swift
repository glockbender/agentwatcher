import AgentWatchCore
import AgentWatchLookup
import AppKit

/// Owns everything about the set of live sessions: ingesting events, watching for their
/// death, retiring the ones that ended, and publishing the result.
///
/// Split out of `AppDelegate` because that class cannot be instantiated in a test, and the
/// rules here — which sessions still have a watcher, when the sweep has anything to do —
/// are exactly the kind that go wrong quietly. `AppDelegate` keeps the menus and windows.
///
/// This stays in the application target on purpose; ADR-0007 says why, and the ordering
/// rules a reader might come here looking for moved to the engine with `receive`.
@MainActor
final class SessionSupervisor {
    /// Slow on purpose. Retiring a closed session and demoting an unwatched one are both
    /// cheap and neither is time-critical.
    static let maintenanceInterval: TimeInterval = 15

    private var engine = SessionStateEngine()
    private var maintenanceTimer: Timer?
    private let settings: WidgetSettingsStore
    private let onChange: ([SessionSnapshot], [AgentUsageLimits]) -> Void
    private let onNotableEvent: (String) -> Void
    private let now: () -> Date
    private let heard: AgentHeardStore
    private let history: SessionHistoryStore
    /// How the app finds agents nobody has told it about. Injected so the rules around it
    /// can be exercised without a machine that happens to be running one.
    private let liveAgentProcesses: () -> [DiscoveredAgentProcess]
    /// When a process started, asked of the system. Injected for the same reason, and used
    /// for one thing: half the identity of a pairing, since macOS reuses process numbers.
    private let agentProcessStartedAt: (Int32) -> Date?
    /// Which session each live agent process is, by process number.
    ///
    /// Written down the moment a hook tells the app both halves, kept across restarts, and
    /// dropped as soon as the process is gone. It is the only honest way back from a running
    /// process to the session it is: a session's row leaves the app long before its agent
    /// stops — dismissed by hand, or swept after a silence — and without this pairing the
    /// next scan can only put up a row with no name, for a session whose name has been in
    /// its transcript all along.
    private lazy var sessionsByAgentProcess: [Int32: RememberedAgentProcess] = Dictionary(
        history.rememberedAgentProcesses.map { ($0.processID, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    /// Rows a person has dismissed by hand, by row identifier.
    ///
    /// Without it the next scan would put the row straight back, and the dismiss button
    /// would be the one control in the widget that does nothing.
    ///
    /// Every dismissed row, not only the ones built from a process. A row is dismissible
    /// while it says `no signal`, while it carries a fault, or after half an hour of silence
    /// — and its agent can be running through all three. Such a row was rebuilt by the next
    /// scan, and once a pairing could name it (`sessionsByAgentProcess`) it came back looking
    /// identical to the one just dismissed.
    ///
    /// It lasts one launch and no longer, and that is the rule rather than an oversight:
    /// seeing everything that runs is worth more than remembering one gesture about it, so a
    /// restart shows every running agent again.
    private var dismissedRowIDs: Set<String> = []

    private lazy var hostRegistry = SessionHostRegistry(
        claudeHome: claudeHome,
        onAgentProcessExit: { [weak self] sessionID in
            self?.handleAgentProcessExit(sessionID: sessionID)
        },
        onViewerProcessExit: { [weak self] sessionID in
            self?.handleViewerProcessExit(sessionID: sessionID)
        }
    )

    /// Claude Code's own folder under the home this app was given, where it keeps a record of
    /// every process it runs.
    private var claudeHome: URL {
        home.appendingPathComponent(".claude", isDirectory: true)
    }

    private lazy var transcripts = TranscriptWatcher(
        settings: settings,
        home: home,
        now: now,
        onUpdates: { [weak self] updates in
            self?.applyTranscript(updates)
        }
    )
    private let home: URL
    private let workspaceNotifications: NotificationCenter

    init(
        settings: WidgetSettingsStore,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        heard: AgentHeardStore = AgentHeardStore(),
        history: SessionHistoryStore,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        now: @escaping () -> Date = { .now },
        liveAgentProcesses: @escaping () -> [DiscoveredAgentProcess] = AgentProcessScanner.liveAgentProcesses,
        agentProcessStartedAt: @escaping (Int32) -> Date? = AgentProcessLocator.startTime(of:),
        onChange: @escaping ([SessionSnapshot], [AgentUsageLimits]) -> Void,
        onNotableEvent: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.home = home
        self.workspaceNotifications = workspaceNotifications
        self.heard = heard
        self.history = history
        self.now = now
        self.liveAgentProcesses = liveAgentProcesses
        self.agentProcessStartedAt = agentProcessStartedAt
        self.onChange = onChange
        self.onNotableEvent = onNotableEvent
    }

    var sessions: [SessionSnapshot] {
        orderedSnapshots()
    }

    /// What each agent's account has left, as the widget shows it under the divider.
    ///
    /// Read directly as well as published, so a redraw that no event asked for — a tooling
    /// change, say — can assemble the widget's whole state without waiting for one.
    var usageLimits: [AgentUsageLimits] {
        Array(engine.usageLimitsBySource.values)
    }

    /// Whether the maintenance timer is currently running.
    ///
    /// Exposed because `AGENTS.md` forbids polling while there is nothing to poll for, and
    /// an invariant nothing can observe is an invariant nothing can hold you to.
    var isPolling: Bool {
        maintenanceTimer != nil
    }

    func start() {
        workspaceNotifications.addObserver(
            self,
            selector: #selector(agentApplicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // A Mac that slept through an agent starting or ending wakes up with a stale list,
        // and waking is a notification rather than a poll.
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        restoreRememberedSessions()
        discoverAgentProcesses()
    }

    /// Puts back the sessions the last launch knew about.
    ///
    /// Only the ones something can still vouch for: a row nothing will ever retire is worse
    /// than a missing one, because it claims a session is there and no event will ever
    /// contradict it. What comes back carries no phase — see `SessionHistory.remembered` —
    /// so the first real hook is still what says what the session is doing.
    private func restoreRememberedSessions() {
        let remembered = history.remembered
        guard !remembered.isEmpty else {
            return
        }

        let restored = engine.restore(remembered.filter { hostRegistry.isHostAlive($0) })
        for remembered in restored {
            // Vouched for again like the agent itself: a terminal closed while the app was
            // down is no viewer, and the file's word for it would point the click at nothing.
            let snapshot = refreshViewer(of: remembered, evenIfKnown: true)
            // The same call an event makes, and for the same reason: this is what will report
            // the session's death. Without it a restored row could never leave — its phase
            // claims no work, so the sweep has nothing to demote and nothing to retire.
            hostRegistry.associate(snapshot)
            // A restored session may have no pairing on record — a file written before
            // pairings existed has none — and restoring it has just proved the process is
            // the one this session was last seen in, which is all a pairing claims.
            rememberAgentProcess(of: snapshot)
        }
        // Published even when nothing came back, because this is also what rewrites the file
        // without the sessions that did not: their agents are gone, and the next launch has no
        // reason to ask about them again.
        publish()
        // After publishing, because this is the one thing the memory cannot hold: how long ago
        // the session actually did something. The one phase it can move is a remembered wait,
        // and only by the session's own evidence — see `catchUp` and `confirmRememberedWait`.
        let waits = engine.rememberedWaitsAwaitingEvidence
        let asked = transcripts.catchUp(sessions: restored, waits: waits)
        // A wait nobody answers keeps its row at `no signal` for good, so a session the
        // reader declined is answered here instead, with the only honest answer available:
        // nothing was read, so nothing is claimed.
        for id in waits.keys where !asked.contains(id) {
            engine.confirmRememberedWait(forSessionWithID: id, evidence: nil)
        }
        onNotableEvent("restored \(restored.count) of \(remembered.count) session(s) from the last launch")
    }

    func stop() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        transcripts.stop()
        workspaceNotifications.removeObserver(self)
    }

    /// Whether a transcript is being read right now, for the menu to say so plainly.
    var isReadingTranscripts: Bool {
        transcripts.isPolling
    }

    /// When the transcript is next due to be read.
    ///
    /// Exposed only so a test can see that an event actually moved the schedule. The rule
    /// lives in `TranscriptReadSchedule`; what this proves is that the reader is told.
    var nextTranscriptReadAt: Date? {
        transcripts.nextReadAt
    }

    /// How many sessions the transcript reader currently has a complaint about.
    var faultedSessionCount: Int {
        engine.snapshots.values.filter { $0.monitoringFault != nil }.count
    }

    /// Picks up a changed poll interval, including one that turned reading off.
    func transcriptSettingsChanged() {
        transcripts.settingsChanged()
    }

    func reach(for snapshot: SessionSnapshot) -> SessionReach {
        hostRegistry.reach(for: snapshot)
    }

    /// A click that reached nothing is said out loud rather than swallowed.
    ///
    /// The row always answers a click, so "nothing happened" is a state a person can now
    /// arrive at, and an app whose whole job is noticing things should not be silent about
    /// its own. The card said as much before the click; this is the record afterwards.
    @discardableResult
    func focus(_ snapshot: SessionSnapshot) -> Bool {
        let outcome = hostRegistry.focus(snapshot)
        if !outcome.raised {
            // With the reason when there is one: a background session's click can fail on the
            // way to its terminal — no record of the process, no job in it, Ghostty declining
            // — and "nothing to bring forward" alone would hide which.
            if case .missing(let reason) = outcome.tab {
                onNotableEvent("\(Self.label(snapshot)) · \(reason); nothing to bring forward")
            } else {
                onNotableEvent("\(Self.label(snapshot)) · nothing to bring forward")
            }
        } else if case .missing(let reason) = outcome.tab {
            onNotableEvent("\(Self.label(snapshot)) · \(reason); window only")
        }
        return outcome.raised
    }

    // MARK: - Events

    @discardableResult
    func ingest(_ request: HookIngressRequest) -> EventEnvelope? {
        // Before anything is made of it, and regardless of whether anything can be: the
        // arrival is the fact that proves this agent's hooks reach the app, and an event that
        // is refused arrived just the same.
        heard.record(request.source, at: now())

        let event: EventEnvelope
        var snapshot: SessionSnapshot
        do {
            event = try HookIngressProcessor.normalize(request, observedAt: now())
            let change = try engine.receive(event)
            // Whatever left as this event landed: its watcher goes with it, since the row it
            // watched is gone. The watcher the arriving session gets is installed by
            // `associate` below, keyed on its own identifier.
            for departure in change.rowsThatLeft {
                hostRegistry.forget(departure.row)
                if departure.reason == .itsProcessNowRunsAnother {
                    onNotableEvent(
                        "\(Self.label(departure.row)) · closed session dropped; its process now runs another")
                }
            }
            // Said out loud, both times. A row that never appeared is otherwise
            // indistinguishable from an event that never arrived — the one failure a monitor
            // is not allowed to have.
            guard let landedOn = change.row else {
                onNotableEvent(Self.withheldNote(for: event, withheld: change.withheld))
                return event
            }
            snapshot = landedOn
            // Not on a start that names no original: the copy's process first runs the
            // two-second session `--resume` leaves behind, and claiming the terminal for that
            // stub is a line in the log about a row retired a moment later, followed by the
            // same line for the copy. Any later hook of a row asks again.
            if event.kind != .sessionStarted || event.forkedFromSessionID != nil {
                snapshot = refreshViewer(of: snapshot)
            }
            // Said once, when it happens — a row that silently changed its process and the kind
            // of place it runs in, or that silently split in two, would be one a person cannot
            // check against. The engine says what it decided; every later event of the copy
            // lands on the row without a word.
            switch change.note {
            case let .continued(foldedOwnRow):
                let place = event.clientKind == .background ? "in the background" : "in another process"
                let folding = foldedOwnRow ? "; the copy's own row folded in" : ""
                onNotableEvent("\(Self.label(snapshot)) · continued \(place) by a copy of the session\(folding)")
            case let .released(copies, rowWasClosed):
                // Two different things, and the difference is the whole news. Either the row
                // has split — the session and its copy both run — or the copy had ended and
                // closed the row, and the session behind it turns out to be alive.
                onNotableEvent(Self.releaseNote(for: snapshot, copies: copies, rowWasClosed: rowWasClosed))
            case nil:
                // The documented mark of a copy, with nothing to join: the sender could not
                // name the original — a spelling of the arguments it does not know, or a copy
                // made without new arguments at all. Said out loud, because the alternative is
                // a second row for one conversation appearing in silence, which is the very
                // thing the rule above exists to stop.
                if event.kind == .sessionStarted, event.startedAsCopy, event.forkedFromSessionID == nil {
                    onNotableEvent(
                        "\(Self.label(snapshot)) · started as a copy of a session this app cannot name; a row of its own"
                    )
                }
            }
        } catch {
            // Said out loud rather than dropped. This app's whole job is to notice things,
            // and until now the one thing it never reported was its own failure to understand
            // an event: no line, no counter, nothing anywhere. That also made a real question
            // unanswerable — whether a missing start was refused on arrival or never sent.
            onNotableEvent("\(request.source.rawValue.capitalized) · refused \(Self.refusal(error))")
            return nil
        }
        hostRegistry.associate(snapshot)
        rememberAgentProcess(of: snapshot)
        // The reader is told before publishing, so the schedule is already pulled in by the
        // time `publish` hands it the session list.
        transcripts.noteHook(at: event.observedAt)
        publish()
        return event
    }

    /// Records which terminal shows a background session, asked of Claude Code's registry.
    ///
    /// `/bg` leaves the terminal it was typed in showing the session (`SessionSnapshot
    /// .viewerProcessID`), and the registry is the one place that says which: the record of
    /// the interactive process names the job as parked. Asked on the row's own events while
    /// no viewer is known — the exit watch takes a known one away when its process ends, and
    /// a person may open the session in a terminal again at any time — and on restore
    /// regardless, because the file's answer is from another launch. A row built from a
    /// process is left alone: it has no hooks, and its process is all it is.
    ///
    /// Said out loud when the answer changes, in the words the card will use, because a row
    /// that silently changed what a click on it does is one a person cannot check against.
    private func refreshViewer(of snapshot: SessionSnapshot, evenIfKnown: Bool = false) -> SessionSnapshot {
        guard snapshot.clientKind == .background, snapshot.discoveredProcess == nil,
            snapshot.phase != .sessionClosed
        else {
            return snapshot
        }
        guard evenIfKnown || snapshot.viewerProcessID == nil else {
            return snapshot
        }
        let viewer = viewerProcessID(of: snapshot)
        guard viewer != snapshot.viewerProcessID,
            let updated = engine.setViewer(processID: viewer, forSessionWithID: snapshot.id)
        else {
            return snapshot
        }
        onNotableEvent(
            viewer != nil
                ? "\(Self.label(updated)) · on screen in the terminal that sent it to the background; a click goes there"
                : Self.viewerGoneNote(for: updated))
        return updated
    }

    /// The terminal showing a background session has closed. The session runs on — its own
    /// process is what the row lives and dies with — but the window is gone, and a click on
    /// the row opens the session again rather than raising it.
    private func handleViewerProcessExit(sessionID: String) {
        guard
            engine.snapshots[sessionID]?.viewerProcessID != nil,
            let snapshot = engine.setViewer(processID: nil, forSessionWithID: sessionID)
        else {
            return
        }
        hostRegistry.associate(snapshot)
        publish()
        onNotableEvent(Self.viewerGoneNote(for: snapshot))
    }

    private static func releaseNote(for snapshot: SessionSnapshot, copies: [String], rowWasClosed: Bool) -> String {
        guard !rowWasClosed else {
            return
                "\(label(snapshot)) · reopened: the copy that closed this row had ended, and the session itself works on"
        }
        return copies.count == 1
            ? "\(label(snapshot)) · works on beside its copy; the copy is a row of its own from here on"
            : "\(label(snapshot)) · works on beside its copies; they are rows of their own from here on"
    }

    private static func withheldNote(for event: EventEnvelope, withheld: RowChange.Withholding?) -> String {
        let label = label(sessionID: SessionSnapshot.id(source: event.source, sessionLabel: event.sessionID))
        return withheld == .endedWithoutWorking
            ? "\(label) · background session ended without taking a turn; it never had a row"
            : "\(label) · background session started; no row until it takes a turn"
    }

    private static func viewerGoneNote(for snapshot: SessionSnapshot) -> String {
        "\(label(snapshot)) · its terminal is gone; a click now opens it with `claude attach`"
    }

    /// The terminal process attached to this session's job, from Claude Code's records of
    /// its processes, or `nil` when none is running.
    private func viewerProcessID(of snapshot: SessionSnapshot) -> Int32? {
        guard
            let agentProcessID = snapshot.agentProcessID,
            let own = try? Data(
                contentsOf: BackgroundSessionAttach.sessionRecordURL(
                    claudeHome: claudeHome, agentProcessID: agentProcessID)),
            let jobID = BackgroundSessionAttach.jobID(inSessionRecord: own)
        else {
            return nil
        }
        let sessions = claudeHome.appendingPathComponent("sessions", isDirectory: true)
        let records =
            ((try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
        // A process that runs another row's conversation is nobody's viewer. After `/bg` a
        // person can go back to the original in that same terminal and work on there — the
        // original speaks for itself, the copy becomes a row of its own — and whether Claude
        // Code clears `parkedJobId` then is not measured; the record is not what settles it.
        // A row the scan built from the process is not a conversation the app knows of: the
        // app may have started with no memory of the session `/bg` was typed in, and then the
        // terminal is a live `claude` with nothing heard from it. Named as the viewer it is
        // claimed, and the next scan withdraws that row.
        let runningAnotherRow = Set(
            engine.snapshots.values
                .filter { $0.id != snapshot.id && $0.phase != .sessionClosed && $0.discoveredProcess == nil }
                .compactMap(\.agentProcessID))
        return BackgroundSessionAttach.viewerProcessID(ofJob: jobID, inSessionRecords: records) {
            processID, recordedStart in
            guard !runningAnotherRow.contains(processID), let startedAt = agentProcessStartedAt(processID) else {
                return false
            }
            // A number handed out again belongs to a stranger. Claude Code writes its own
            // reading of the start into the record; the two clocks are compared loosely.
            guard let recordedStart else {
                return true
            }
            return abs(startedAt.timeIntervalSince(recordedStart)) < 60
        }
    }

    func remove(_ snapshot: SessionSnapshot) {
        guard engine.removeSession(id: snapshot.id) != nil else {
            return
        }
        dismissedRowIDs.insert(snapshot.id)
        hostRegistry.forget(snapshot)
        publish()
        onNotableEvent("\(Self.label(snapshot)) · session removed")
    }

    private func handleAgentProcessExit(sessionID: String) {
        // A row built from a process is not a session that ended — it is a row that was
        // never more than the process it named. Closing it would leave a tombstone for a
        // session nobody ever saw anything about, and under "remove closed sessions by
        // hand" that tombstone would stay until it was dismissed.
        if let discovered = engine.snapshots[sessionID], discovered.discoveredProcess != nil {
            engine.removeSession(id: sessionID)
            hostRegistry.forgetSession(id: sessionID)
            publish()
            onNotableEvent("\(Self.label(discovered)) · agent process ended")
            return
        }
        guard let snapshot = engine.markSessionClosed(id: sessionID, at: now()) else {
            return
        }
        // The exit already proves the host is gone, so its registry entry is stale from this
        // moment; keeping it would leave a dead PID behind until manual dismissal.
        hostRegistry.forget(snapshot)
        publish()
        onNotableEvent("\(Self.label(snapshot)) · session closed")
    }

    // MARK: - Agents nobody announced

    /// Puts a row on the widget for every live agent the app has never heard from, and takes
    /// away the rows whose agent has gone.
    ///
    /// A session the app was not running for is invisible otherwise, and no event is coming
    /// to fix that: the next hook arrives with the next turn, and a session waiting for a
    /// person may never take one.
    ///
    /// Deliberately not on a timer of its own. `AGENTS.md` forbids polling while there is
    /// nothing to poll for, so this runs where the app already had a reason to look: at
    /// launch, when the Mac wakes, and when the menu is opened. The maintenance sweep calls
    /// it too, but that is a bonus rather than a trigger — the sweep runs only while some
    /// session claims work, and a widget whose only rows are discovered ones runs no sweep
    /// at all.
    ///
    /// What that leaves uncovered is an agent starting while the app runs and its hooks stay
    /// silent. The menu already says when an agent has never been heard from, which is the
    /// honest answer to that case.
    func discoverAgentProcesses() {
        let live = liveAgentProcesses().map(recognised)
        // Dismissals are not pruned here, and that is deliberate. The set lives one launch
        // and holds one string per press of a button, so nothing about it can grow; while
        // pruning it against the live processes could *undo* a press — a dismissed session
        // whose agent is running but has no pairing yet would come back as a nameless row,
        // because its identifier is the session's and the row's would be the process's.
        //
        // Pairings are pruned, because those do grow: they are written to the file, and one
        // is added for every session ever heard from.
        let pairingsBefore = sessionsByAgentProcess
        let liveProcessLabels = Set(live.map(\.processLabel))
        sessionsByAgentProcess = sessionsByAgentProcess.filter { liveProcessLabels.contains($0.value.processLabel) }

        let change = engine.reconcileDiscoveredProcesses(
            live.filter { !dismissedRowIDs.contains($0.snapshotID) }
        )
        // A forgotten pairing is a change with no row to show for it, and it still has to
        // reach the file: publishing is the only thing that writes, and skipping it would
        // leave the list growing on disk for as long as the app kept running.
        if !change.isEmpty || sessionsByAgentProcess != pairingsBefore {
            for id in change.removedIDs {
                hostRegistry.forgetSession(id: id)
                // Said out loud, like the arrival above. A row that leaves silently is the
                // one thing a person cannot check against: "it came back" and "it never
                // left" look identical on the widget.
                onNotableEvent("\(Self.label(sessionID: id)) · agent gone; row withdrawn")
            }
            for snapshot in change.added {
                // The same watch a session gets from its first hook. It is what will take
                // the row away again, and without it a row whose agent quits would sit there
                // until somebody dismissed it.
                hostRegistry.associate(snapshot)
                onNotableEvent("\(Self.label(snapshot)) · agent running, nothing heard from it")
            }
            publish()
        }
        // Outside that, because a scan that changed nothing is exactly when the last one's
        // declined catch-up gets its second chance.
        catchUpRecognisedRows()
    }

    /// Asks the transcript of every row that knows which session it is.
    ///
    /// Only those rows: the rest have no file anyone can say is theirs, which is what
    /// `DiscoveredAgentProcess` means by never guessing one.
    ///
    /// Every one of them on every scan, not only the rows this scan added, because a
    /// catch-up can be declined — the reader takes one read at a time, and at launch the
    /// restored sessions are already being read when the scan runs. Nothing else would ever
    /// ask again: a row whose silence is expected gets no scheduled reads, so a declined
    /// catch-up would leave it nameless for the whole launch. A row that was read already
    /// holds a watch, and the reader passes over it.
    ///
    /// Called after publishing, never before: the reader drops every watch the published
    /// list does not contain, so a read asked for ahead of the list it belongs to is a read
    /// thrown away. `restoreRememberedSessions` does the same.
    private func catchUpRecognisedRows() {
        let recognised = engine.snapshots.values
            .filter { $0.discoveredProcess?.knownSessionLabel != nil }
            .sorted { $0.arrivalIndex < $1.arrivalIndex }
        guard !recognised.isEmpty else {
            return
        }
        transcripts.catchUp(sessions: recognised)
    }

    /// The same process, told which session it is when a hook has said so before.
    ///
    /// The source has to match as well as the number: the pairing's label is half of a
    /// session identifier, and pinning it to the wrong agent would invent an identifier for
    /// a session that does not exist.
    private func recognised(_ process: DiscoveredAgentProcess) -> DiscoveredAgentProcess {
        guard
            let pairing = sessionsByAgentProcess[process.processID],
            pairing.processLabel == process.processLabel,
            pairing.source == process.source
        else {
            return process
        }
        return process.knowing(sessionLabel: pairing.sessionLabel)
    }

    /// Writes down which session a process is, so that a later launch can recognise it.
    ///
    /// Only for a session that has spoken for itself. A row built from a process would pair
    /// a process with its own name, which says nothing that the process did not already say.
    private func rememberAgentProcess(of snapshot: SessionSnapshot) {
        guard snapshot.discoveredProcess == nil, let processID = snapshot.agentProcessID else {
            return
        }
        // Asking the system when the process started is a `sysctl`, and this runs on every
        // hook. A number already paired with this session is every hook after the first, and
        // the answer for it cannot have changed: the pairing goes when the process does.
        guard sessionsByAgentProcess[processID]?.sessionLabel != snapshot.sessionLabel else {
            return
        }
        guard let startedAt = agentProcessStartedAt(processID) else {
            return
        }
        sessionsByAgentProcess[processID] = RememberedAgentProcess(
            source: snapshot.source,
            processID: processID,
            startedAt: startedAt,
            sessionLabel: snapshot.sessionLabel
        )
    }

    @objc private func systemDidWake(_ notification: Notification) {
        discoverAgentProcesses()
    }

    /// Quitting the agent's application is an observed fact. A PID check is not usable here:
    /// Codex leaves helper processes behind, so they would read as still running.
    @objc private func agentApplicationTerminated(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let source = AgentSource(desktopBundleIdentifier: application.bundleIdentifier)
        else {
            return
        }

        let closed = engine.markDesktopSessionsClosed(source: source, at: now())
        guard !closed.isEmpty else {
            return
        }
        for snapshot in closed {
            hostRegistry.forget(snapshot)
        }
        publish()
        onNotableEvent("\(source.rawValue.capitalized) · desktop app closed \(closed.count) session(s)")
    }

    // MARK: - Maintenance

    /// Retires sessions the widget should stop showing, and demotes ones nobody can vouch
    /// for to "no signal".
    func runMaintenance() {
        let moment = now()
        // Free: this sweep exists only while some session claims work, and the scan costs
        // about a millisecond. It is not what makes discovery work — see
        // `discoverAgentProcesses` for the triggers that do.
        discoverAgentProcesses()
        let disconnected = engine.markUnwatchedSessionsDisconnected(
            now: moment,
            after: SessionFreshnessEvaluator.defaultDisconnectAfter,
            watchedSessionIDs: externallyWatchedSessionIDs()
        )
        let retired: [String] =
            switch settings.closedSessionRetention {
            case .manual: []
            case let .after(seconds): engine.removeExpiredClosedSessions(now: moment, retention: seconds)
            }

        guard !disconnected.isEmpty || !retired.isEmpty else {
            updateMaintenanceTimer()
            return
        }
        for id in retired {
            hostRegistry.forgetSession(id: id)
        }
        for snapshot in disconnected {
            onNotableEvent("\(Self.label(snapshot)) · no signal")
        }
        publish()
    }

    /// Whether the sweep has anything it could act on.
    ///
    /// Keyed on work, not on sessions: a finished session sitting in `completed`, or a closed
    /// one under "keep until dismissed", can never produce work, and waking every fifteen
    /// seconds for it would be polling in the resting state.
    static func hasMaintenanceWork(
        sessions: some Collection<SessionSnapshot>,
        retention: ClosedSessionRetention
    ) -> Bool {
        sessions.contains { snapshot in
            SessionFreshnessEvaluator.tracksFreshness(for: snapshot.phase)
                || (snapshot.phase == .sessionClosed && retention != .manual)
        }
    }

    /// Sessions whose death some watcher will report on its own: a live process-exit watch,
    /// or a desktop application that is running now and will announce its own termination.
    /// A desktop session whose application is already gone is deliberately not counted —
    /// nothing is left to send that notification.
    ///
    /// One lookup per bundle identifier, not one per session: the answer is the same for
    /// every session of a source, and this runs on the maintenance sweep.
    private func externallyWatchedSessionIDs() -> Set<String> {
        var identifiers = hostRegistry.watchedSessionIDs
        var isRunning: [String: Bool] = [:]
        for snapshot in engine.snapshots.values where snapshot.clientKind == .desktop {
            guard let bundleIdentifier = snapshot.source.desktopBundleIdentifier else {
                continue
            }
            let running =
                isRunning[bundleIdentifier]
                ?? !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
            isRunning[bundleIdentifier] = running
            if running {
                identifiers.insert(snapshot.id)
            }
        }
        return identifiers
    }

    // MARK: - The transcript

    /// Folds one poll's worth of transcript into the sessions.
    ///
    /// Both sources run in parallel and nearly always agree, so only a disagreement is
    /// logged: a fact the transcript delivered that the hooks did not. Logging the agreements
    /// too would bury the handful of lines this exists to produce.
    ///
    /// Reachable from a test rather than private, for the same reason `isPolling` is: this
    /// is where the two sources meet, and a rule nothing can observe is a rule nothing can
    /// hold you to.
    func applyTranscript(_ updates: [TranscriptUpdate]) {
        var changed = false
        for update in updates {
            // Every fact moves the age a row shows, whether or not it also changed the
            // session, so any fact at all is worth republishing for.
            changed = changed || !update.facts.isEmpty
            for fact in update.facts {
                guard let snapshot = engine.apply(fact, toSessionWithID: update.sessionID) else {
                    // Applying nothing has two meanings, and only one is worth a line. A fact
                    // about a session that is still here changed nothing because the hooks had
                    // already said the same — the ordinary case, and a line for each would bury
                    // the handful this log exists to produce. A fact about a session that is
                    // gone was thrown away, and that is the transcript's half of the refusal a
                    // hook already gets: without it a missing ending cannot be told apart from
                    // one that arrived and was dropped. No session means no agent to name it
                    // by, so the line carries the id the read was scheduled under.
                    if engine.snapshots[update.sessionID] == nil {
                        onNotableEvent(
                            "\(update.sessionID) · transcript · refused \(Self.name(of: fact)) — no such session")
                    }
                    continue
                }
                // Same shape as a hook line, because the two kinds are read side by side.
                onNotableEvent("\(Self.label(snapshot)) · transcript · \(Self.name(of: fact))")
            }
            // After the facts and never before. A fact is weighed against the age it has to be
            // newer than, and moving the age first would let this same increment answer that
            // question — an interruption would be judged stale by the very lines it arrived
            // with.
            if let at = update.newestRecordAt,
                engine.markObserved(at: at, forSessionWithID: update.sessionID) != nil
            {
                changed = true
            }

            // Not announced, unlike a fact. These move on their own schedule — the context
            // count changes every turn — and a debug log carrying them would drown the handful
            // of lines it exists to show.
            if engine.applySignals(update.signals, toSessionWithID: update.sessionID) != nil {
                changed = true
            }

            // Same reasoning, and the same silence. A name read from the file is what the
            // session answers to now; the remembered one is what it answered to when the app
            // last ran.
            if let description = update.description,
                engine.applyDescription(description, toSessionWithID: update.sessionID) != nil
            {
                changed = true
            }

            // Last of the four, because it is the only one that can move a phase, and it may
            // do so only on what the three above have just read out of the same file.
            if engine.rememberedWaitsAwaitingEvidence[update.sessionID] != nil,
                let waiting = engine.confirmRememberedWait(
                    forSessionWithID: update.sessionID,
                    evidence: update.waitEvidence
                )
            {
                changed = true
                onNotableEvent("\(Self.label(waiting)) · still waiting for you, as its transcript agrees")
            }

            if let snapshot = engine.setMonitoringFault(update.fault, forSessionWithID: update.sessionID) {
                changed = true
                let name = Self.label(snapshot)
                onNotableEvent(
                    update.fault.map { "\(name) · \(monitoringFaultSummary(for: $0))" }
                        ?? "\(name) · monitoring recovered"
                )
            }
        }
        guard changed else {
            return
        }
        publish()
    }

    /// Why an event was refused, safe to write into a local log.
    ///
    /// Only the normalisation error carries anything that came off the socket, and it
    /// sanitises that itself. The rest are protocol numbers.
    private static func refusal(_ error: Error) -> String {
        switch error {
        case let error as HookCaptureError:
            // The first gate, and the one an unregistered hook name meets: the redactor
            // refuses a name that is not on the allowlist before anything is parsed. It
            // carries nothing off the socket, which is why nothing here is sanitised.
            switch error {
            case .unsupportedDeclaredEvent: "a hook name this app does not handle"
            case .expectedJSONObject: "an event whose payload is not an object"
            }
        case let error as EventNormalizationError:
            error.safeDescription
        case let error as HookIngressError:
            if case let .unsupportedSchemaVersion(version) = error {
                "an event in protocol version \(version), which this app does not speak"
            } else {
                "an event this app could not read"
            }
        case let error as EventIngestionError:
            if case let .unsupportedSchemaVersion(version) = error {
                "an event in protocol version \(version), which this app does not speak"
            } else {
                "an event this app could not read"
            }
        default:
            "an event this app could not read"
        }
    }

    /// The prefix every line about one session carries: the agent, then the session.
    ///
    /// One place rather than a copy per call site. A log where some lines name the session
    /// and some do not is worse than either habit — the unnamed ones read as though they
    /// were about no session in particular, and with two sessions running that is the only
    /// question worth asking. The identifier is the hashed label that crossed the wire.
    private static func label(_ snapshot: SessionSnapshot) -> String {
        label(sessionID: snapshot.id)
    }

    /// The same prefix from the identifier alone, for a row that is already gone. The
    /// identifier carries its source in front of the colon — `SessionSnapshot.id(source:sessionLabel:)`.
    private static func label(sessionID id: String) -> String {
        let source = id.prefix { $0 != ":" }
        return "\(source.capitalized) · \(id)"
    }

    private static func name(of fact: TranscriptFact) -> String {
        switch fact {
        case let .callStarted(_, kind, _): "\(kind.rawValue) call started"
        case .callReturned: "call ended"
        case .callFailed: "call failed"
        case .workEnded: "background work ended"
        case .turnInterrupted: "turn interrupted"
        }
    }

    func publish() {
        let snapshots = orderedSnapshots()
        // The waits go with the snapshots, because a row under check says `no signal` while
        // the file still has to remember what it is waiting for. Without them a publish
        // during the check — and `restoreRememberedSessions` makes one — writes the demoted
        // row and the wait is gone before its transcript has answered.
        history.update(
            snapshots,
            awaiting: engine.rememberedWaitsAwaitingEvidence,
            agentProcesses: sessionsByAgentProcess.values.sorted { $0.processID < $1.processID },
            at: now()
        )
        onChange(snapshots, usageLimits)
        updateMaintenanceTimer()
        transcripts.update(sessions: snapshots)
    }

    /// Sorted, because `snapshots` is a dictionary and its order changes on rehash. The
    /// widget skips a report equal to the one before it — that is what keeps the row under
    /// the pointer alive — and an unordered list would report a change on every rehash.
    private func orderedSnapshots() -> [SessionSnapshot] {
        engine.snapshots.values.sorted { $0.arrivalIndex < $1.arrivalIndex }
    }

    private func updateMaintenanceTimer() {
        guard
            Self.hasMaintenanceWork(
                sessions: engine.snapshots.values,
                retention: settings.closedSessionRetention
            )
        else {
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        guard maintenanceTimer == nil else {
            return
        }

        maintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runMaintenance()
            }
        }
    }
}
