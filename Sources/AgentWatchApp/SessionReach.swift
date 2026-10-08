import AgentWatchCore

/// Whether a click on a session's row has anything to bring forward — the one thing the hover
/// card says about where a click lands, since a click that works needs no sentence.
///
/// Cases and not a `Bool`: `nowhere` reads at the call site as a fact about the session,
/// where `false` reads only as something not being true — and the third case is a click that
/// does something else entirely.
///
/// Optional where it is passed, and `nil` is not `nowhere`: one means nobody asked, the other
/// means somebody asked and the answer was no.
enum SessionReach: Equatable, Sendable {
    /// An application holds the session, and a click raises it.
    case anApplication
    /// Nothing does — the host has quit, or the session never had a window of its own.
    case nowhere
    /// The session's terminal was closed and its agent stayed behind, and a click ends the
    /// agent this way — `nil` when nothing here can, and then the click has nothing to do.
    /// The way stays out of the session model: it is the process's, read at the moment the
    /// card or the click asks.
    case closedTerminal(AgentEnding?)
    /// The session is a headless run: no window, and a click offers to end the run this way —
    /// `nil` when nothing here can, because its process is unknown or no longer the run's.
    case headlessRun(AgentEnding?)
}

/// What a click on a session's row came to.
enum SessionClick: Equatable, Sendable {
    /// A window came forward.
    case raised
    /// Nothing did, and the log says why.
    case nothingRaised
    /// The session is broken — its terminal is gone and its agent runs on — or it is a
    /// headless run, and ending its agent this way is put to the person who clicked before
    /// anything is done (ADR-0013, ADR-0021).
    case asksToEndAgent(AgentEnding)
}

/// How a click ends an agent: one its closed terminal left behind, two ways because a terminal
/// is closed two ways (ADR-0013), or a headless run (ADR-0021).
enum AgentEnding: Equatable, Sendable {
    /// The kernel took the terminal away and the agent hangs waiting for it to take its last
    /// output. Discarding that output through this device lets it exit.
    case discardOutput(devicePath: String)
    /// Ghostty closed the tab and kept the terminal, and the agent runs on in it. The hang-up
    /// the closed tab never sent ends it and the shell it was started from, the agent first.
    case hangUp(processIDs: [Int32])
    /// A headless run, asked to stop with `SIGTERM` (`HeadlessRun`).
    case terminate(processID: Int32)
}

/// Why a click asks to end an agent, which is what the question says.
enum EndAgentReason: Equatable, Sendable {
    case closedTerminal
    case headlessRun

    init(for session: SessionSnapshot) {
        self = session.hostKind == .headless ? .headlessRun : .closedTerminal
    }
}

/// The question a click on a broken session or a headless run puts, the same in the widget
/// and in the menu.
enum EndAgentQuestion {
    /// Whether the question still holds: the session is still without its terminal, or still a
    /// run that has not ended, and something here can still end its agent — a question whose
    /// yes could do nothing would be a lie. Asked again whenever what is shown is rebuilt.
    @MainActor
    static func holds(for session: SessionSnapshot?, reach: (SessionSnapshot) -> SessionReach) -> Bool {
        guard let session else {
            return false
        }
        switch reach(session) {
        case .closedTerminal(.some): return session.phase == .terminalClosed
        case .headlessRun(.some): return session.phase != .sessionClosed
        case .anApplication, .nowhere, .closedTerminal(nil), .headlessRun(nil): return false
        }
    }

    /// What the question calls the session: its name, or its project when it has none.
    static func name(of session: SessionSnapshot) -> String? {
        session.title?.nonEmpty ?? session.projectName?.nonEmpty
    }
}
