import Foundation

/// One of Ghostty's terminals, as it describes itself.
public struct GhosttyTerminal: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Why Agent Watch will not ask Ghostty to bring a tab forward.
public enum GhosttyFocusRefusal: Equatable, Sendable {
    /// The session has no name yet. Claude writes the name into the tab title itself, so
    /// until it has one there is nothing on either side to match on. Temporary, and it
    /// resolves itself within the first minutes of a session.
    case sessionHasNoName

    /// No tab is named after this session. It may be running in a terminal that is not this
    /// one, or in a tab whose title something else has overwritten.
    case noTabMatches

    /// More than one tab would do, and picking one of them would be a guess. Two sessions
    /// can be given the same name by the agent, and then the name stops identifying either.
    case severalTabsMatch
}

/// Bringing a Ghostty tab forward by the name the agent wrote into it.
///
/// The whole key is that Claude titles the terminal itself, with the session name that Agent
/// Watch already shows in the widget — so the two sides agree on a string neither had to
/// invent. See `docs/session-focus-research.md`.
///
/// Everything here is a rule over values somebody else read, which is why it is in the core:
/// the terminals come from an Apple event and the answer is decided without a disk, an app,
/// or a permission.
public enum GhosttyFocus {
    public enum Decision: Equatable, Sendable {
        /// Focus this terminal, by the id Ghostty gave for it.
        case ask(terminalID: String)
        case decline(GhosttyFocusRefusal)
    }

    /// Which terminal is this session's, if exactly one is.
    ///
    /// **Ends with, not equals.** Claude puts a glyph for its own state in front of the name
    /// — `◑` and `✳` in the two samples taken, and the set belongs to the agent, so listing
    /// it here would be a copy that goes stale. The suffix is the part both sides agree on.
    ///
    /// **Exactly one, or nothing.** Two matches mean the name has stopped identifying a
    /// session, and choosing one of them would move a person to a tab that is not theirs —
    /// worse than not moving them at all.
    public static func decision(among terminals: [GhosttyTerminal], sessionName: String?) -> Decision {
        let name = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return .decline(.sessionHasNoName)
        }
        let matches = terminals.filter { terminal in
            terminal.name.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(name)
        }
        guard let only = matches.first else {
            return .decline(.noTabMatches)
        }
        guard matches.count == 1 else {
            return .decline(.severalTabsMatch)
        }
        return .ask(terminalID: only.id)
    }

    /// Whether this identifier can be written into a script.
    ///
    /// Ghostty's identifiers are `UUID`s, and requiring that shape is what keeps the script
    /// a script: the tab *name* comes from an agent's output and is never interpolated
    /// anywhere, precisely so that a name cannot become a command.
    public static func isAddressableTerminalID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}

extension GhosttyFocusRefusal {
    /// How this reads in the log, and whether it is worth a line at all.
    public var attempt: TabFocusAttempt {
        switch self {
        case .sessionHasNoName: .missing("no session name yet to find the tab by")
        case .noTabMatches: .missing("no terminal tab is named after this session")
        case .severalTabsMatch: .missing("several terminal tabs match this session's name")
        }
    }
}

extension JetBrainsFocusRefusal {
    /// How this reads in the log, and whether it is worth a line at all.
    ///
    /// A host that is not a JetBrains IDE is the ordinary case — a terminal, a desktop
    /// client — and saying it on every press would bury the three that mean something is
    /// missing.
    public var attempt: TabFocusAttempt {
        switch self {
        case .notAJetBrainsIDE: .unaddressable
        case .bundleNamesNoScheme: .missing("IDE registers no scheme to address it by")
        case .daemonMissing: .missing("no JetBrains daemon to carry the address")
        case .pluginNeverAnswered: .missing("IDE plugin has never answered")
        }
    }
}
