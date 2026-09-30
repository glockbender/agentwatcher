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
    case closedTerminal(ClosedTerminalEnding?)
}

/// What a click on a session's row came to.
enum SessionClick: Equatable, Sendable {
    /// A window came forward.
    case raised
    /// Nothing did, and the log says why.
    case nothingRaised
    /// The session is broken — its terminal is gone and its agent runs on — and ending the
    /// agent this way is put to the person who clicked before anything is done (ADR-0013).
    case asksToEndAgent(ClosedTerminalEnding)
}

/// How a click ends an agent its closed terminal left behind (ADR-0013). Two ways, because a
/// terminal is closed two ways.
enum ClosedTerminalEnding: Equatable, Sendable {
    /// The kernel took the terminal away and the agent hangs waiting for it to take its last
    /// output. Discarding that output through this device lets it exit.
    case discardOutput(devicePath: String)
    /// Ghostty closed the tab and kept the terminal, and the agent runs on in it. The hang-up
    /// the closed tab never sent ends it and the shell it was started from, the agent first.
    case hangUp(processIDs: [Int32])
}

/// The question a broken session's click puts, the same in the widget and in the menu.
enum EndAgentQuestion {
    /// Whether the question still holds: the session is still without its terminal, and
    /// something here can still end its agent — a question whose yes could do nothing would be
    /// a lie. Asked again whenever what is shown is rebuilt.
    @MainActor
    static func holds(for session: SessionSnapshot?, reach: (SessionSnapshot) -> SessionReach) -> Bool {
        guard let session, session.phase == .terminalClosed, case .closedTerminal(.some) = reach(session) else {
            return false
        }
        return true
    }

    /// What the question calls the session: its name, or its project when it has none.
    static func name(of session: SessionSnapshot) -> String? {
        session.title?.nonEmpty ?? session.projectName?.nonEmpty
    }
}
