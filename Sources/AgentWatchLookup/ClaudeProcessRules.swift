import AgentWatchCore
import Foundation

/// Claude Code, as the kernel sees it: a program installed under `…/claude/versions/`, a few
/// long-lived helpers run from the same program, and one session per process a person
/// started — which is what lets its sessions be found from its processes.
///
/// A process is the agent's by its path or by its own record in Claude Code's registry. The
/// path is how it was installed, and the kernel stops naming it that way in two measured cases
/// — an update deleted the version, or a background session gave the file a second name — so
/// the record answers where the path cannot (`ClaudeSessionRegistry`). The path stays, because
/// not every session gets a record.
public struct ClaudeProcessRules: AgentProcessRules {
    /// How far up the tree a candidate is checked for an agent above it.
    ///
    /// The same depth `AgentProcessLocator` walks down from a hook, and for the same reason:
    /// a bound is what makes a cycle in the parent chain harmless.
    private static let maximumAncestorDepth = 16

    let registry: ClaudeSessionRegistry

    public init(registry: ClaudeSessionRegistry = ClaudeSessionRegistry()) {
        self.registry = registry
    }

    public func agentProcessID(among ancestors: [ProcessSnapshot]) -> Int32? {
        ancestors.first(where: isAgentProcess)?.processID
    }

    public func clientKind(
        among ancestors: [ProcessSnapshot],
        argumentsOfProcess: (Int32) -> [String]?
    ) -> SessionClientKind? {
        guard let agentIndex = ancestors.firstIndex(where: isAgentProcess) else {
            return nil
        }
        // The same process this hook will report as the session's, asked what it is, and
        // then everything above it. A background session has one of the agent's own
        // helpers somewhere in that chain — it *is* `claude bg-spare`, or it is a session
        // sent to the background with `/bg`, which the pty host `claude --bg-pty-host`
        // starts as a child of its own. Either way there is no terminal above it, and so
        // no window the widget could ever raise. Measured on 2.1.269: the host runs from
        // `ClaudeCode.app`, not from `versions/`, so it is found by its words, not its path.
        //
        // Only Claude's own processes are asked, which is what "helper of the agent's"
        // means. The words are ordinary ones, and something far above the session may
        // have been started with them for reasons of its own — `emacs --daemon` is how
        // Emacs is normally run, and a terminal inside it is the parent of everything
        // typed there.
        let runsUnderAHelper = ancestors[agentIndex...].contains { process in
            let arguments = argumentsOfProcess(process.processID) ?? []
            return (isAgentProcess(process) || Self.isTheAgentsExecutable(arguments))
                && Self.isHelperCommand(arguments)
        }
        return runsUnderAHelper ? .background : .cli
    }

    /// Reads the original out of a fork's arguments: `--fork-session` says the process is a
    /// copy, and `--resume` (or `-r`, or `--resume=…`) names what it was copied from — the
    /// transcript file, named after the session, when Claude Code started the copy itself;
    /// the identifier, when a person typed it. Measured on 2.1.269. A resume without
    /// `--fork-session` keeps its identifier and is nothing to continue from.
    ///
    /// `/bg` and `/fork` continue a session in a new process under a new identifier, and the
    /// widget would otherwise draw a second row for the same conversation. No hook field
    /// names the original; the process's own arguments do.
    ///
    /// Only the session the process was started for is the copy, and `--session-id` is what
    /// names it — Claude Code always passes it. The stub session `--resume` leaves behind on
    /// the same process reads the same arguments and is nobody's continuation: aliased onto
    /// the original's row, its start would reset the row and its end would close it two
    /// seconds later. So a command without `--session-id` — one a person typed — continues
    /// nothing, although it may well be a real fork: the copy then gets a row of its own,
    /// which is one row too many at worst, where a stub read as a copy costs a live row.
    public func forkedFromSessionID(arguments: [String], forSessionID sessionID: String) -> String? {
        let words = Self.commandWords(arguments)
        guard words.contains("--fork-session"), Self.optionValue(named: ["--session-id"], in: words) == sessionID
        else {
            return nil
        }
        guard let resumed = Self.optionValue(named: ["--resume", "-r"], in: words) else {
            return nil
        }
        guard resumed.contains("/") else {
            return resumed
        }
        let identifier = URL(fileURLWithPath: resumed).deletingPathExtension().lastPathComponent
        return identifier.isEmpty ? nil : identifier
    }

    /// Every live Claude session, as much as a row can honestly say about one.
    ///
    /// One `claude` process a person started is one session — the agent's own helpers are
    /// dropped in `sessionProcessIDs` — and a Claude hook carries its process number, which
    /// is what lets a discovered row hand itself over to the session when the first hook
    /// finally arrives.
    ///
    /// Measured on a machine with 156 processes: listing them costs 0.03 ms and reading
    /// every executable path 0.9 ms, which is why this can be done wherever the app already
    /// has a reason to look rather than on a timer of its own.
    public func liveSessions() -> [DiscoveredAgentProcess] {
        let candidates = sessionProcessIDs()
        return
            candidates
            .filter { !Self.hasAgentAncestor($0, among: candidates) }
            .compactMap { processID in
                // A process with no start time is one that has already gone: the same call
                // answers both questions, which is why the row is built from its result
                // rather than from the listing that named the process a moment ago.
                guard let startedAt = AgentProcessLocator.startTime(of: processID) else {
                    return nil
                }
                return DiscoveredAgentProcess(
                    source: .claude,
                    processID: processID,
                    startedAt: startedAt,
                    projectName: AgentProcessScanner.workingDirectoryName(of: processID),
                    clientKind: clientKind(
                        among: AgentProcessLocator.ancestorSnapshots(startingAt: processID),
                        argumentsOfProcess: AgentProcessLocator.commandArguments(of:)
                    )
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    /// Whether some Claude process was started with exactly these words after the program —
    /// `["attach", "3345bfdf"]` for a viewer of that job.
    ///
    /// Asked before a background session's press opens a viewer of its own, so that a second
    /// press finds the first viewer's tab instead of opening another. Helpers are not dropped
    /// here, because a viewer is one of the processes `sessionProcessIDs` drops.
    public func isRunning(withWords words: [String]) -> Bool {
        let recorded = registry.liveProcessIDs()
        return AgentProcessScanner.allProcessIDs().contains { processID in
            guard let snapshot = AgentProcessLocator.snapshot(of: processID),
                recorded.contains(processID) || Self.isClaudeProcess(snapshot)
            else {
                return false
            }
            return Self.commandWords(AgentProcessLocator.commandArguments(of: processID) ?? []) == words
        }
    }

    /// Whether this process is the Claude CLI itself, by its path or by its record.
    ///
    /// Every rule here asks it, the scanner of every process on the machine and the sender of
    /// a hook's ancestors: two answers to "what is a Claude process" would drift apart.
    func isAgentProcess(_ snapshot: ProcessSnapshot) -> Bool {
        Self.isClaudeProcess(snapshot) || registry.recordsLiveProcess(snapshot.processID)
    }

    /// Whether the path is the one Claude Code installs its versions under.
    static func isClaudeProcess(_ snapshot: ProcessSnapshot) -> Bool {
        guard let executablePath = snapshot.executablePath else {
            return false
        }
        let components = URL(fileURLWithPath: executablePath).pathComponents.map {
            $0.lowercased()
        }
        guard components.count >= 3 else {
            return false
        }

        let versionDirectoryIndex = components.count - 2
        return components[versionDirectoryIndex] == "versions"
            && components[versionDirectoryIndex - 1] == "claude"
    }

    /// Whether a process running the Claude executable is one of the agent's own helpers
    /// rather than a session.
    ///
    /// Claude Code runs several long-lived processes from the same executable — measured on
    /// this machine: `claude daemon run …`, `claude bg-pty-host …` and `claude bg-spare …`.
    /// They are indistinguishable from a session by executable path, and each one became a
    /// row nobody could focus and nothing could ever name: a helper sends no hooks, and it
    /// has no terminal window to bring forward.
    ///
    /// The list is what was observed rather than every subcommand Claude Code has. The rule
    /// only ever removes a row, so a helper it does not know yet is today's behaviour and
    /// nothing worse.
    ///
    /// `attach` is on the list for a reason of its own: not a helper of the agent's but a
    /// viewer of a person's. It shows a background session in the terminal it is typed into,
    /// and that session has a row already — the background one, and a click on that row is
    /// what opens the viewer to begin with (`BackgroundSessionAttach`). A row for the viewer
    /// too would be nameless, would never hear a hook of its own, and would stand beside the
    /// row it duplicates.
    ///
    /// Asked of a process's arguments and nothing else, so the whole rule can be exercised
    /// without a machine that happens to be running one.
    static func isHelperCommand(_ arguments: [String]) -> Bool {
        guard let subcommand = commandWords(arguments).first else {
            return false
        }
        // `claude bg-pty-host …` in one build, `claude --bg-pty-host …` in the next — the same
        // helper, named as a word or as a flag. Measured on 2.1.269 and 2.1.270 side by side.
        // One `--` and no more: everything else a word can start with is somebody else's.
        let name = subcommand.hasPrefix("--") ? String(subcommand.dropFirst(2)) : subcommand
        return helperCommands.contains(name)
    }

    /// The words a process was started with, after the program itself.
    ///
    /// A helper renames itself: `claude bg-pty-host` arrives as one argument, with the job
    /// written into the name. A subcommand typed by a person is the next argument instead, so
    /// both shapes are read as the same list of words. Two rules ask it — whether a process is
    /// one of the agent's helpers, and whether a viewer of one particular job is running — and
    /// one reading keeps them from drifting apart.
    static func commandWords(_ arguments: [String]) -> [String] {
        guard let program = arguments.first else {
            return []
        }
        // A program named by its path carries no words in the first argument, whatever spaces
        // the path has in it; only a renamed process does, and it renames itself to a bare name.
        let renamedWords = program.contains("/") ? [] : program.split(separator: " ").dropFirst().map(String.init)
        return renamedWords + arguments.dropFirst()
    }

    private static let helperCommands: Set<String> = ["daemon", "bg-pty-host", "bg-spare", "attach"]

    /// Whether these are the arguments of a process running the agent's own program, asked of
    /// the name it was started under — for the helpers `isClaudeProcess` does not recognise,
    /// which know themselves by a path ending in `claude` (the pty host runs from
    /// `ClaudeCode.app`, not from `versions/`, measured on 2.1.269) or by the name a renamed
    /// process gives itself, `claude <something>`.
    private static func isTheAgentsExecutable(_ arguments: [String]) -> Bool {
        guard let program = arguments.first else {
            return false
        }
        return program == "claude" || program.hasSuffix("/claude") || program.hasPrefix("claude ")
    }

    /// The value of an option written either as `--name value` or as `--name=value`; `nil`
    /// when the option is absent, or has no value, or its value is another option.
    private static func optionValue(named names: [String], in words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            if names.contains(word) {
                guard words.indices.contains(index + 1) else {
                    return nil
                }
                let value = words[index + 1]
                return value.isEmpty || value.hasPrefix("-") ? nil : value
            }
            for name in names where word.hasPrefix(name + "=") {
                let value = String(word.dropFirst(name.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func sessionProcessIDs() -> Set<Int32> {
        // The records are listed once, not looked up for every process on the machine.
        let recorded = registry.liveProcessIDs()
        var found: Set<Int32> = []
        for processID in AgentProcessScanner.allProcessIDs() {
            guard let snapshot = AgentProcessLocator.snapshot(of: processID),
                recorded.contains(processID) || Self.isClaudeProcess(snapshot)
            else {
                continue
            }
            // Dropped here rather than from the finished list, and the order is the rule: a
            // helper left among the candidates would hide a real session running under it,
            // because the ancestry check below removes anything with an agent above it.
            guard !Self.isHelperCommand(AgentProcessLocator.commandArguments(of: processID) ?? []) else {
                continue
            }
            found.insert(processID)
        }
        return found
    }

    /// A helper an agent started for itself is not a second session.
    ///
    /// The other half of the same rule is `isHelperCommand`, which catches the helpers this
    /// one cannot: a helper whose parent has gone is reparented to `launchd` and has no agent
    /// above it any more.
    ///
    /// Only removes rows, never adds one, which is what makes it safe to apply before the
    /// case has been seen in the wild: an agent that turns out never to spawn another agent
    /// loses nothing to this check.
    private static func hasAgentAncestor(_ processID: Int32, among candidates: Set<Int32>) -> Bool {
        var current = processID
        for _ in 0..<maximumAncestorDepth {
            guard let parent = AgentProcessLocator.parentProcessID(of: current), parent > 1, parent != current
            else {
                return false
            }
            if candidates.contains(parent) {
                return true
            }
            current = parent
        }
        return false
    }
}
