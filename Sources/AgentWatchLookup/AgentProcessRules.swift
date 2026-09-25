import AgentWatchCore

/// What one agent's sessions look like from the kernel's side: which process is the agent,
/// where its session runs, and whether its processes can be counted as sessions at all.
///
/// One conformance per agent, and the only place in this module that tells one agent from
/// another; `AgentProcessLocator` asks the kernel and knows no agent. Every conformance
/// answers in the same shared terms — a process number, a `SessionClientKind`, a
/// `DiscoveredAgentProcess` — and an agent that cannot tell something answers with nothing
/// rather than the question being left out. Codex's hooks carry no process number and its
/// processes do not count sessions; that is said once, in `CodexProcessRules`, instead of as
/// an `if source == .claude` at every caller.
///
/// The same rules serve the hook sender and the app's scanner, and have to: a row the scanner
/// builds and the row its first hook builds must agree about which process is the session's.
/// Why the split is by agent here and by concern elsewhere: `docs/agent-integration.md` §1а.
public protocol AgentProcessRules: Sendable {
    /// The process a hook names as its session's, found among the hook's ancestors — nearest
    /// first — or `nil` when this agent's hooks carry no process number.
    func agentProcessID(among ancestors: [ProcessSnapshot]) -> Int32?

    /// Where the session runs, or `nil` when the ancestry does not make it trustworthy.
    ///
    /// - Parameter argumentsOfProcess: what a process was started with; handed in so a test
    ///   can state it instead of needing a process that really was.
    func clientKind(
        among ancestors: [ProcessSnapshot],
        argumentsOfProcess: (Int32) -> [String]?
    ) -> SessionClientKind?

    /// The session this one was copied from, read from the arguments of the agent's process,
    /// or `nil` when it is no copy — raw, for the redactor.
    func forkedFromSessionID(arguments: [String], forSessionID sessionID: String) -> String?

    /// Every live session of this agent that can be found from its processes alone, whether or
    /// not it has ever sent a hook — empty for an agent whose processes do not count sessions.
    func liveSessions() -> [DiscoveredAgentProcess]
}

extension AgentSource {
    /// The rules for this agent's processes. The one place in this module that switches over
    /// the agents.
    public var processRules: any AgentProcessRules {
        switch self {
        case .claude: ClaudeProcessRules()
        case .codex: CodexProcessRules()
        }
    }
}
