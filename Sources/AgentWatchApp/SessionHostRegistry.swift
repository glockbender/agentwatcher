import AgentWatchCore
import AgentWatchLookup
import AppKit
import Darwin

@MainActor
final class SessionHostRegistry {
    private struct SessionHost {
        let agentProcessID: Int32
        var applicationProcessID: pid_t?
        /// The terminal showing a background session, as last watched. Compared on every
        /// `associate` so the watch moves when the viewer does and is not remade on every hook.
        var viewerProcessID: Int32?
    }

    private let onAgentProcessExit: (String) -> Void
    private let onViewerProcessExit: (String) -> Void
    /// Claude Code's own folder, where it keeps a record of every process it runs — the one
    /// place a background session's job identifier can be read from. A parameter so a test
    /// can point it at a folder of its own.
    private let claudeHome: URL
    private var hosts: [String: SessionHost] = [:]
    private lazy var exitWatcher = SessionProcessExitWatcher { [weak self] key in
        if let sessionID = Self.sessionID(ofViewerWatch: key) {
            self?.onViewerProcessExit(sessionID)
        } else {
            self?.onAgentProcessExit(key)
        }
    }

    /// - Parameter onViewerProcessExit: the terminal showing a background session has closed.
    ///   The session runs on; only its window went, so this is reported apart from the
    ///   agent's own exit.
    init(
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        onAgentProcessExit: @escaping (String) -> Void,
        onViewerProcessExit: @escaping (String) -> Void = { _ in }
    ) {
        self.claudeHome = claudeHome
        self.onAgentProcessExit = onAgentProcessExit
        self.onViewerProcessExit = onViewerProcessExit
    }

    /// The viewer's watch shares the watcher with the agent's, under a key of its own.
    private static let viewerWatchSuffix = "\u{1}viewer"

    private static func viewerWatchKey(for sessionID: String) -> String {
        sessionID + viewerWatchSuffix
    }

    private static func sessionID(ofViewerWatch key: String) -> String? {
        key.hasSuffix(viewerWatchSuffix) ? String(key.dropLast(viewerWatchSuffix.count)) : nil
    }

    func associate(_ snapshot: SessionSnapshot) {
        guard snapshot.source == .claude, let agentProcessID = snapshot.agentProcessID else {
            return
        }
        if hosts[snapshot.id]?.agentProcessID != agentProcessID {
            hosts[snapshot.id] = SessionHost(
                agentProcessID: agentProcessID,
                applicationProcessID: hostApplicationProcessID(for: agentProcessID),
                viewerProcessID: hosts[snapshot.id]?.viewerProcessID
            )
            exitWatcher.watch(sessionID: snapshot.id, processID: agentProcessID)
        }
        watchViewer(of: snapshot)
    }

    /// The terminal showing a background session is watched like the agent itself, so that
    /// its closing takes the window away from the row — without ending the session, which
    /// runs on in its own process. The watch follows the viewer: a new one is watched, a
    /// gone one unwatched, and an unchanged one left alone.
    private func watchViewer(of snapshot: SessionSnapshot) {
        guard var host = hosts[snapshot.id], host.viewerProcessID != snapshot.viewerProcessID else {
            return
        }
        host.viewerProcessID = snapshot.viewerProcessID
        hosts[snapshot.id] = host
        let key = Self.viewerWatchKey(for: snapshot.id)
        if let viewerProcessID = snapshot.viewerProcessID {
            exitWatcher.watch(sessionID: key, processID: viewerProcessID)
        } else {
            exitWatcher.unwatch(sessionID: key)
        }
    }

    /// Whether anything holds this session that a click could bring forward, asked now.
    ///
    /// Asked every time rather than remembered from the association. The previous rule
    /// resolved the host once — on the first hook, or while the app was still starting up —
    /// and kept that answer for the life of the row, so a resolution that failed at that one
    /// moment left the row saying there was nothing to bring forward long after its
    /// application was back.
    func reach(for snapshot: SessionSnapshot) -> SessionReach {
        application(for: snapshot) == nil ? .nowhere : .anApplication
    }

    /// What one click achieved.
    ///
    /// Two answers rather than one, because the two steps can disagree: the host is raised
    /// by us and we know whether that worked, while the tab is selected by the IDE itself
    /// and all we know is whether we managed to ask. `raised` keeps meaning exactly what it
    /// meant before — the host came forward — and never grows to mean "landed on the tab".
    struct FocusOutcome {
        let raised: Bool
        let tab: TabFocusAttempt
    }

    /// The way to this session's tab, found before its host is raised.
    ///
    /// Found first and followed second, because the two are one question. A route ends at a
    /// window of its own — Ghostty's `focus` raises the terminal's window, the IDE plugin
    /// picks the project's — and that is exactly the reason not to bring every other window
    /// of the host along on the way there.
    enum TabRoute {
        /// Ghostty focuses this terminal: window and tab in the one call.
        case ghostty(terminalID: String)
        /// The IDE plugin picks the window and the tab; this is the address it answers to.
        case jetBrains(URL)
        /// Nothing here addresses a tab, and the reason belongs in the log.
        case noTab(TabFocusAttempt)
    }

    /// Which of the host's windows come forward.
    ///
    /// All of them only when nothing is going to pick one. `activateAllWindows` is the wide
    /// net for a host whose tab cannot be addressed: the session is in one of those windows
    /// and Agent Watch cannot say which. Where a route exists it is the wrong net — every
    /// window of the host comes forward, and then the route puts the right one on top of the
    /// pile it has just made. What the person sees is the pile: reported for Ghostty with
    /// several windows open, and true of the IDE plugin in the same way.
    ///
    /// `activateAllWindows` although it is deprecated, and that is a measurement rather than
    /// inertia: it still works from a background process on macOS 15, and the newer spelling
    /// could not be shown to raise a buried window of the same application any better —
    /// there was only one on screen to test with.
    static func activationOptions(for route: TabRoute) -> NSApplication.ActivationOptions {
        switch route {
        case .ghostty, .jetBrains: []
        case .noTab: [.activateAllWindows]
        }
    }

    /// Brings the session's host forward, then asks it for the tab.
    ///
    /// The caller is told rather than left to guess: with the row always answering a click,
    /// a click that could do nothing has to be distinguishable from one that did something.
    ///
    /// The order is deliberate. The plugin's own focus is written on the assumption that the
    /// application is already forward — it picks the right *window* and leaves the raising
    /// alone — and raising first also keeps today's behaviour intact for every host that has
    /// no plugin behind it. The route, though, is decided before the raise: how many windows
    /// to bring forward is a question only the route can answer.
    @discardableResult
    func focus(_ snapshot: SessionSnapshot) -> FocusOutcome {
        // A background session has no application anywhere above it and never will — its
        // tree ends at `launchd` — so there is no host to raise. What it has is a door, and
        // the click opens that instead. Unless a terminal is showing it already: then the
        // terminal is the host, reached below like any other, and the door would only open
        // the session a second time beside it.
        if snapshot.hostKind == .background {
            return attachInTerminal(snapshot)
        }
        guard let application = application(for: snapshot) else {
            return FocusOutcome(raised: false, tab: .unaddressable)
        }
        let route = tabRoute(of: snapshot, in: application)
        let raised = application.activate(options: Self.activationOptions(for: route))
        return FocusOutcome(raised: raised, tab: follow(route))
    }

    /// Opens a background session in a new Ghostty tab with `claude attach`.
    ///
    /// The job to attach to comes from Claude Code's record of the agent process, read now
    /// rather than remembered: the record appears when the session is moved to the
    /// background, which can be twenty minutes after its first hook. Each way the trip can
    /// end early is named in the outcome, because a press that does nothing and a log that
    /// says only that is the one thing this app must not do. `BackgroundSessionAttach` holds
    /// the rules; this is only the disk, the script and the raise.
    ///
    /// `raised` is true once the tab is there: the tab *is* the session coming forward, and
    /// bringing Ghostty in front of everything else is the same best effort as for any host.
    private func attachInTerminal(_ snapshot: SessionSnapshot) -> FocusOutcome {
        guard let agentProcessID = snapshot.agentProcessID else {
            return FocusOutcome(raised: false, tab: .missing("no agent process to look the job up by"))
        }
        let record = BackgroundSessionAttach.sessionRecordURL(claudeHome: claudeHome, agentProcessID: agentProcessID)
        guard let contents = try? Data(contentsOf: record) else {
            return FocusOutcome(
                raised: false, tab: .missing("Claude Code keeps no record of process \(agentProcessID)"))
        }
        guard let jobID = BackgroundSessionAttach.jobID(inSessionRecord: contents) else {
            return FocusOutcome(
                raised: false, tab: .missing("Claude Code's record of the process names no job to attach to"))
        }
        // Asked before Ghostty is: an Apple event to an application that is not installed fails
        // the same way one refused by the Automation setting does, and the two need different
        // words from the person.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyScripting.bundleIdentifier) != nil
        else {
            return FocusOutcome(raised: false, tab: .missing("Ghostty is not installed, and the attach opens there"))
        }
        // A viewer already on screen is brought forward rather than doubled. Ghostty answers
        // nothing when it is not running or not allowed to be asked, and an empty list then
        // leads to the tab being opened — which is also what launches Ghostty.
        let decision = BackgroundSessionAttach.decision(
            among: GhosttyScripting.terminals() ?? [],
            jobID: jobID,
            viewerIsRunning: AgentProcessScanner.isClaudeRunning(withWords: ["attach", jobID])
        )
        switch decision {
        case .focus(let terminalID):
            guard GhosttyScripting.focus(terminalID: terminalID) else {
                return FocusOutcome(raised: false, tab: .missing("Ghostty refused to focus the viewer's tab"))
            }
        case .openTab(let line):
            guard let terminalID = GhosttyScripting.openTab(typing: line) else {
                return FocusOutcome(raised: false, tab: .missing("Ghostty opened no tab; check Automation permission"))
            }
            _ = GhosttyScripting.focus(terminalID: terminalID)
        case .decline:
            return FocusOutcome(
                raised: false, tab: .missing("the job identifier in Claude Code's record is not one that may be typed"))
        }
        // Without `activateAllWindows`, for the same reason as every other addressed tab: the
        // terminal above has already been focused, and Ghostty's `focus` brings its window
        // with it. Raising the rest of them now would bury the one just asked for.
        _ = NSRunningApplication.runningApplications(withBundleIdentifier: GhosttyScripting.bundleIdentifier)
            .first?.activate(options: [])
        return FocusOutcome(raised: true, tab: .asked)
    }

    /// Who can be asked for this session's tab, and how.
    ///
    /// Two hosts can be asked, by two entirely different routes, and which one applies is
    /// decided by the application rather than by the session: a JetBrains IDE through its
    /// plugin, Ghostty through its AppleScript dictionary. Everything else has no way to
    /// address a tab, and that is the ordinary answer rather than a fault.
    private func tabRoute(
        of snapshot: SessionSnapshot,
        in application: NSRunningApplication
    ) -> TabRoute {
        if application.bundleIdentifier == GhosttyScripting.bundleIdentifier {
            return ghosttyRoute(of: snapshot)
        }
        return ideRoute(of: snapshot, in: application)
    }

    private func ghosttyRoute(of snapshot: SessionSnapshot) -> TabRoute {
        guard let terminals = GhosttyScripting.terminals() else {
            // Ghostty answered nothing, and by far the likeliest reason is that this app has
            // not been allowed to control it. Named rather than swallowed, because the fix
            // is one switch in System Settings and nothing else would ever hint at it.
            return .noTab(.missing("Ghostty did not answer; check Automation permission"))
        }
        switch GhosttyFocus.decision(among: terminals, sessionName: snapshot.title) {
        case .ask(let terminalID): return .ghostty(terminalID: terminalID)
        case .decline(let refusal): return .noTab(refusal.attempt)
        }
    }

    private func ideRoute(
        of snapshot: SessionSnapshot,
        in application: NSRunningApplication
    ) -> TabRoute {
        // The plugin looks for the tab whose shell is an ancestor of this process: the
        // terminal showing a background session, where there is one.
        guard let bundleURL = application.bundleURL, let agentProcessID = snapshot.hostProcessID else {
            return .noTab(.unaddressable)
        }
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: JetBrainsInstallation.dataDirectoryName(ofApplicationAt: bundleURL),
            productScheme: JetBrainsInstallation.productScheme(ofApplicationAt: bundleURL),
            isDaemonInstalled: JetBrainsInstallation.isDaemonInstalled(),
            hasAnsweredPing: JetBrainsInstallation.hasAnsweredPing(ofApplicationAt: bundleURL),
            agentProcessID: agentProcessID
        )
        switch decision {
        case .ask(let url): return .jetBrains(url)
        case .decline(let refusal): return .noTab(refusal.attempt)
        }
    }

    /// Walking the route the host has just been raised for.
    private func follow(_ route: TabRoute) -> TabFocusAttempt {
        switch route {
        case .ghostty(let terminalID):
            guard GhosttyScripting.focus(terminalID: terminalID) else {
                return .missing("Ghostty refused to focus the tab")
            }
            return .asked
        case .jetBrains(let url):
            // Fire and forget, and it cannot be otherwise: the address goes to the JetBrains
            // daemon, which hands it to the IDE, which runs the plugin. Nothing comes back
            // along that path. What the plugin did is in the IDE's own log.
            _ = NSWorkspace.shared.open(url)
            return .asked
        case .noTab(let attempt):
            return attempt
        }
    }

    /// Sessions this registry has a live process-exit watch on. Reported rather than
    /// inferred, so the engine never assumes a watcher that `associate` declined to create.
    var watchedSessionIDs: Set<String> {
        Set(hosts.keys)
    }

    func forget(_ snapshot: SessionSnapshot) {
        forgetSession(id: snapshot.id)
    }

    func forgetSession(id: String) {
        hosts.removeValue(forKey: id)
        exitWatcher.unwatch(sessionID: id)
        exitWatcher.unwatch(sessionID: Self.viewerWatchKey(for: id))
    }

    /// The same question, asked of the running system.
    func isHostAlive(_ snapshot: SessionSnapshot) -> Bool {
        Self.isHostAlive(
            snapshot,
            processStartedAt: AgentProcessLocator.startTime(of:),
            isApplicationRunning: { bundleIdentifier in
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
            }
        )
    }

    /// Whether a session remembered from a previous launch still has an agent behind it.
    ///
    /// The order of the two questions is the whole rule. A desktop session is vouched for by
    /// its application, because Codex leaves helper processes behind when it quits — the very
    /// reason `agentApplicationTerminated` exists — so a process check would report a session
    /// as live on the strength of a helper whose app is gone.
    ///
    /// Probes are passed in so the rule can be exercised without real processes.
    static func isHostAlive(
        _ snapshot: SessionSnapshot,
        processStartedAt: (Int32) -> Date?,
        isApplicationRunning: (String) -> Bool
    ) -> Bool {
        if snapshot.clientKind == .desktop, let bundleIdentifier = snapshot.source.desktopBundleIdentifier {
            return isApplicationRunning(bundleIdentifier)
        }
        guard let agentProcessID = snapshot.agentProcessID else {
            return false
        }
        return isStillTheAgent(
            agentProcessID: agentProcessID,
            lastObservedAt: snapshot.lastObservedAt,
            processStartedAt: processStartedAt
        )
    }

    /// Whether the process now holding this number can still be the session's agent.
    ///
    /// A PID is not an identity: macOS reuses them, and a process that started after this
    /// session's last event cannot be the one that sent it.
    ///
    /// Its own function because two paths need it. Vouching for a remembered row always
    /// asked; deciding which application to raise did not, and so walked the process tree
    /// from whatever now holds the number — which is a stranger's tree once the number has
    /// been handed out again.
    static func isStillTheAgent(
        agentProcessID: Int32,
        lastObservedAt: Date,
        processStartedAt: (Int32) -> Date?
    ) -> Bool {
        guard let startedAt = processStartedAt(agentProcessID) else {
            return false
        }
        return startedAt <= lastObservedAt
    }

    /// The application to raise for this session, decided in the order the answers can be
    /// trusted.
    ///
    /// The live process tree first: it is the only source that is true *now*, and walking it
    /// again is a handful of `sysctl` calls. The remembered answer second, because a session
    /// whose agent has exited has no tree left to walk and its row may still be worth
    /// raising. The agent's own desktop application last, for a client that runs no process
    /// of its own to walk up from.
    private func application(for snapshot: SessionSnapshot) -> NSRunningApplication? {
        // A background session with no terminal showing it has no application, by definition
        // of what background means: its tree ends at `launchd`. None is named — not from a
        // walk, and not from memory either. The memory is the trap: a hover while a terminal
        // still showed the session remembered that terminal's application, and once the
        // terminal was gone the card promised to bring it forward while the click attached.
        guard snapshot.hostKind != .background else {
            return nil
        }
        // From the process the session is read in: its own, or the terminal showing a
        // background one — the copy's own tree ends at `launchd` and would answer nothing.
        if let agentProcessID = snapshot.hostProcessID,
            // Before walking it: the tree under a reused number belongs to a stranger, and
            // the answer would be an application this session was never in.
            Self.isStillTheAgent(
                agentProcessID: agentProcessID,
                lastObservedAt: snapshot.lastObservedAt,
                processStartedAt: AgentProcessLocator.startTime(of:)
            ),
            let applicationProcessID = hostApplicationProcessID(for: agentProcessID),
            let application = NSRunningApplication(processIdentifier: applicationProcessID)
        {
            // Kept for when the agent is gone and the tree can no longer be walked — but
            // only as an update to a record `associate` already made. Creating one here
            // would put the session into `watchedSessionIDs`, which the engine reads as
            // "somebody will report this session's death", without arming the watch that
            // would report it: the session would stop being demoted and have nobody left to
            // retire it. Only the application is updated: the record's process numbers are
            // what the watches are keyed on, and the process walked from here may be the
            // viewer's, not the agent's — written over the agent's it would have `associate`
            // tear down and re-arm both watches on the next hook after every hover.
            hosts[snapshot.id]?.applicationProcessID = applicationProcessID
            return application
        }

        if let applicationProcessID = hosts[snapshot.id]?.applicationProcessID,
            let application = NSRunningApplication(processIdentifier: applicationProcessID)
        {
            return application
        }

        // Only for a client that *is* the desktop application. A CLI session runs in
        // somebody's terminal, and answering it with the agent's desktop app would raise a
        // window its session was never in — the same rule `isHostAlive` already applies.
        guard snapshot.clientKind == .desktop, let bundleIdentifier = snapshot.source.desktopBundleIdentifier else {
            return nil
        }
        return NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier == bundleIdentifier
        }
    }

    private func hostApplicationProcessID(for agentProcessID: Int32) -> pid_t? {
        var processID = pid_t(agentProcessID)

        for _ in 0..<16 {
            guard
                let parentProcessID = AgentProcessLocator.parentProcessID(of: processID),
                parentProcessID > 1
            else {
                return nil
            }
            if NSRunningApplication(processIdentifier: parentProcessID) != nil {
                return parentProcessID
            }
            processID = parentProcessID
        }

        return nil
    }
}

extension AgentSource {
    /// The desktop application that hosts this agent, when it has one. Claude Code runs
    /// in a terminal and has no bundle of its own, which is why its sessions rely on the
    /// process-exit watcher instead.
    var desktopBundleIdentifier: String? {
        switch self {
        case .claude: nil
        case .codex: "com.openai.codex"
        }
    }

    init?(desktopBundleIdentifier: String?) {
        guard
            let desktopBundleIdentifier,
            let match = AgentSource.allCases.first(where: {
                $0.desktopBundleIdentifier == desktopBundleIdentifier
            })
        else {
            return nil
        }
        self = match
    }
}
