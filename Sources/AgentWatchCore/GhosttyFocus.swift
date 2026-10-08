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
    /// The session has no name yet. The agent writes the name into the tab title itself, so
    /// until it has one there is nothing on either side to match on. Temporary, and it
    /// resolves itself within the first minutes of a session.
    case sessionHasNoName

    /// No tab is named after this session. It may be running in a terminal that is not this
    /// one, or in a tab whose title something else has overwritten.
    case noTabMatches

    /// More than one tab would do, and picking one of them would be a guess. Two sessions
    /// can be given the same name by the agent, and then the name stops identifying either.
    case severalTabsMatch

    /// No tab is named after this session because its tab is gone: Ghostty closed it and
    /// kept the terminal, and the agent runs on in there. Measured on Ghostty 1.3.1, where
    /// such a terminal was still read and drawn but listed nowhere — not by AppleScript, not
    /// in the tab bar, not in the Window menu.
    case tabClosedTerminalKept(held: Int, shown: Int)
}

/// Bringing a Ghostty tab forward by the name the agent wrote into it.
///
/// The whole key is that Claude and Codex title the terminal themselves, with the session name
/// that Agent Watch already shows in the widget — so the two sides agree on a string neither
/// had to invent. See `docs/research/session-focus.md`.
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
    /// **Carries, not equals** — in the shape each agent writes, `carries(_:_:)`.
    ///
    /// **Exactly one, or nothing.** Two matches mean the name has stopped identifying a
    /// session, and choosing one of them would move a person to a tab that is not theirs —
    /// worse than not moving them at all.
    ///
    /// **Gone, not renamed, only on two more facts.** A missing name is also a tab whose
    /// title something overwrote, or a session told not to title its tab at all
    /// (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`). So Ghostty must hold more terminals than it
    /// lists, and another session's name must be on a listed tab — titles do work on this
    /// machine. The count alone proves nothing for long: once a closed tab has kept its
    /// terminal, the count stays higher until Ghostty quits.
    public static func decision(
        among terminals: [GhosttyTerminal],
        sessionName: String?,
        heldTerminalCount: Int? = nil,
        otherSessionNames: [String] = []
    ) -> Decision {
        guard let name = trimmedName(sessionName) else {
            return .decline(.sessionHasNoName)
        }
        let matches = terminals.filter { carries($0, name) }
        guard let only = matches.first else {
            let titlesCarryNames = otherSessionNames.compactMap(trimmedName).contains { other in
                terminals.contains { carries($0, other) }
            }
            if let held = heldTerminalCount, held > terminals.count, titlesCarryNames {
                return .decline(.tabClosedTerminalKept(held: held, shown: terminals.count))
            }
            return .decline(.noTabMatches)
        }
        guard matches.count == 1 else {
            return .decline(.severalTabsMatch)
        }
        return .ask(terminalID: only.id)
    }

    private static func trimmedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether a tab's title carries the name, in either shape an agent writes it. One rule
    /// for both, so the names of other rows can be looked for without knowing whose they are.
    ///
    /// **Claude: at the end.** It puts a glyph for its own state in front of the name — `◑`
    /// and `✳` in the two samples taken, and the set belongs to the agent, so listing it here
    /// would be a copy that goes stale. The suffix is the part both sides agree on.
    ///
    /// **Codex: as a whole part.** It joins its title from parts with ` | ` — by default what
    /// it is doing, the thread's name and the project's folder: `Reply with ok | work` once
    /// a turn has ended, a spinner frame in front while it works, a blinking `Action Required`
    /// in front while it waits (measured on Codex 0.161.0). A part, not a piece of one: a
    /// thread called `Fix` is not the one in `Fix the build | work`.
    private static func carries(_ terminal: GhosttyTerminal, _ name: String) -> Bool {
        let title = terminal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.hasSuffix(name)
            || title.components(separatedBy: " | ").contains { codexPart($0, carries: name) }
    }

    /// Codex shortens a name of more than 48 characters to its first 45 and `...` — read in
    /// its source rather than seen on a screen.
    private static func codexPart(_ part: String, carries name: String) -> Bool {
        let shown = String(part.drop { $0 == " " || isSpinnerFrame($0) })
        if shown == name {
            return true
        }
        guard name.count > codexNameLimit, shown.count == codexNameLimit, shown.hasSuffix("...") else {
            return false
        }
        return name.hasPrefix(shown.dropLast(3))
    }

    private static let codexNameLimit = 48

    /// Codex's spinner is drawn with Braille dots.
    private static func isSpinnerFrame(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) }
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
        case let .tabClosedTerminalKept(held, shown):
            .gone("Ghostty holds \(held) terminals and shows \(shown), none named after this session")
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
