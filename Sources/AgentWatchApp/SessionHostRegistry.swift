import AgentWatchCore
import AgentWatchIngress
import AgentWatchSender
import AppKit
import Darwin

@MainActor
final class SessionHostRegistry {
    private struct SessionHost {
        let agentProcessID: Int32
        let applicationProcessID: pid_t?
    }

    private let onAgentProcessExit: (String) -> Void
    private var hosts: [String: SessionHost] = [:]
    private lazy var exitWatcher = SessionProcessExitWatcher { [weak self] sessionID in
        self?.onAgentProcessExit(sessionID)
    }

    init(onAgentProcessExit: @escaping (String) -> Void) {
        self.onAgentProcessExit = onAgentProcessExit
    }

    func associate(_ snapshot: SessionSnapshot) {
        guard snapshot.source == .claude, let agentProcessID = snapshot.agentProcessID else {
            return
        }
        guard hosts[snapshot.id]?.agentProcessID != agentProcessID else {
            return
        }

        hosts[snapshot.id] = SessionHost(
            agentProcessID: agentProcessID,
            applicationProcessID: hostApplicationProcessID(for: agentProcessID)
        )
        exitWatcher.watch(sessionID: snapshot.id, processID: agentProcessID)
    }

    /// Everything that can honestly be said about where this session is, asked now.
    ///
    /// Asked now rather than remembered from the association, because every part of the
    /// answer moves: an application quits, a project is opened, a session is given a name
    /// twenty minutes in. The previous rule resolved the host once — on the first hook, or
    /// while the app was still starting up — and kept that answer for the life of the row,
    /// so a resolution that failed at that one moment disabled the row's button for good.
    func locator(for snapshot: SessionSnapshot) -> SessionLocator {
        guard let application = application(for: snapshot) else {
            return .nowhere
        }
        return SessionLocator(
            applicationName: application.localizedName,
            projectName: openProjectName(for: snapshot, in: application),
            // Only a session running in a terminal has a tab, and only such a tab carries
            // the session's name — the agent writes it there itself. A desktop client has
            // no tab to name. See `docs/session-focus-research.md`.
            tabName: snapshot.clientKind == .cli ? snapshot.title?.nonEmpty : nil
        )
    }

    /// What one press achieved.
    ///
    /// Two answers rather than one, because the two steps can disagree: the host is raised
    /// by us and we know whether that worked, while the tab is selected by the IDE itself
    /// and all we know is whether we managed to ask. `raised` keeps meaning exactly what it
    /// meant before — the host came forward — and never grows to mean "landed on the tab".
    struct FocusOutcome {
        let raised: Bool
        let tab: TabFocusAttempt
    }

    /// Brings the session's host forward, then asks its IDE for the tab.
    ///
    /// The caller is told rather than left to guess: with the button always pressable, a
    /// press that could do nothing has to be distinguishable from one that did something.
    ///
    /// The order is deliberate. The plugin's own focus is written on the assumption that the
    /// application is already forward — it picks the right *window* and leaves the raising
    /// alone — and raising first also keeps today's behaviour intact for every host that has
    /// no plugin behind it.
    ///
    /// `activateAllWindows` although it is deprecated, and that is a measurement rather than
    /// inertia: it still works from a background process on macOS 15, and the newer spelling
    /// could not be shown to raise a buried window of the same application any better —
    /// there was only one on screen to test with. Raising the *right* window of several is
    /// what the IDE plugin is for; without it, raising all of them is the wider net.
    @discardableResult
    func focus(_ snapshot: SessionSnapshot) -> FocusOutcome {
        guard let application = application(for: snapshot) else {
            return FocusOutcome(raised: false, tab: .unaddressable)
        }
        let raised = application.activate(options: [.activateAllWindows])
        return FocusOutcome(raised: raised, tab: askForTab(of: snapshot, in: application))
    }

    /// Asking whoever owns this host to select the session's tab.
    ///
    /// Two hosts can be asked, by two entirely different routes, and which one applies is
    /// decided by the application rather than by the session: a JetBrains IDE through its
    /// plugin, Ghostty through its AppleScript dictionary. Everything else has no way to
    /// address a tab, and that is the ordinary answer rather than a fault.
    private func askForTab(
        of snapshot: SessionSnapshot,
        in application: NSRunningApplication
    ) -> TabFocusAttempt {
        if application.bundleIdentifier == GhosttyScripting.bundleIdentifier {
            return askGhosttyForTab(of: snapshot)
        }
        return askIDEForTab(of: snapshot, in: application)
    }

    private func askGhosttyForTab(of snapshot: SessionSnapshot) -> TabFocusAttempt {
        guard let terminals = GhosttyScripting.terminals() else {
            // Ghostty answered nothing, and by far the likeliest reason is that this app has
            // not been allowed to control it. Named rather than swallowed, because the fix
            // is one switch in System Settings and nothing else would ever hint at it.
            return .missing("Ghostty did not answer; check Automation permission")
        }
        switch GhosttyFocus.decision(among: terminals, sessionName: snapshot.title) {
        case .ask(let terminalID):
            guard GhosttyScripting.focus(terminalID: terminalID) else {
                return .missing("Ghostty refused to focus the tab")
            }
            return .asked
        case .decline(let refusal):
            return refusal.attempt
        }
    }

    private func askIDEForTab(
        of snapshot: SessionSnapshot,
        in application: NSRunningApplication
    ) -> TabFocusAttempt {
        guard let bundleURL = application.bundleURL, let agentProcessID = snapshot.agentProcessID else {
            return .unaddressable
        }
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: JetBrainsInstallation.dataDirectoryName(ofApplicationAt: bundleURL),
            productScheme: JetBrainsInstallation.productScheme(ofApplicationAt: bundleURL),
            isDaemonInstalled: JetBrainsInstallation.isDaemonInstalled(),
            hasAnsweredPing: JetBrainsInstallation.hasAnsweredPing(ofApplicationAt: bundleURL),
            agentProcessID: agentProcessID
        )
        switch decision {
        case .ask(let url):
            // Fire and forget, and it cannot be otherwise: the address goes to the JetBrains
            // daemon, which hands it to the IDE, which runs the plugin. Nothing comes back
            // along that path. What the plugin did is in the IDE's own log.
            _ = NSWorkspace.shared.open(url)
            return .asked
        case .decline(let refusal):
            return refusal.attempt
        }
    }

    /// Which open project window of this IDE to expect the session in.
    ///
    /// Answered by the IDE's files rather than by us: `recentProjects.xml` is where it keeps
    /// the mapping, and reading it costs no permission. A host that is not a JetBrains IDE
    /// has no such list and answers nothing, which is the correct answer for Ghostty.
    ///
    /// Only a project the file calls open. The name is used to tell a person which *window*
    /// to look at, and a closed project has none — the file was seen listing a project as
    /// open three hours after it was closed, so the flag is the weaker of the two claims and
    /// the wording must not outrun it. What the session's own project is called is already
    /// on the card, from the session itself.
    ///
    /// The path never leaves this function — `docs/architecture.md` §15. What comes out is
    /// the project's name.
    private func openProjectName(for snapshot: SessionSnapshot, in application: NSRunningApplication) -> String? {
        guard
            let bundleURL = application.bundleURL,
            let agentProcessID = snapshot.agentProcessID,
            let workingDirectory = AgentProcessLocator.workingDirectoryPath(of: agentProcessID)
        else {
            return nil
        }
        let project = SessionPlace.project(
            containing: workingDirectory,
            among: JetBrainsInstallation.projects(ofApplicationAt: bundleURL)
        )
        return project?.isOpen == true ? project?.name : nil
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
        if let agentProcessID = snapshot.agentProcessID,
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
            // retire it.
            if hosts[snapshot.id] != nil {
                hosts[snapshot.id] = SessionHost(
                    agentProcessID: agentProcessID,
                    applicationProcessID: applicationProcessID
                )
            }
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
