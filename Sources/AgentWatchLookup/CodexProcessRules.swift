import AgentWatchCore
import Foundation

/// Codex, as the kernel sees it: a desktop application or a command-line program, and nothing
/// that says which of its sessions a process is.
public struct CodexProcessRules: AgentProcessRules {
    public init() {}

    /// Codex's hooks carry no process number in any form, so there is nothing to name.
    public func agentProcessID(among ancestors: [ProcessSnapshot]) -> Int32? {
        nil
    }

    public func clientKind(
        among ancestors: [ProcessSnapshot],
        argumentsOfProcess: (Int32) -> [String]?
    ) -> SessionClientKind? {
        if ancestors.contains(where: Self.isDesktopProcess) {
            return .desktop
        }
        return ancestors.contains(where: Self.isCLIProcess) ? .cli : nil
    }

    /// Codex continues a session under a new process without saying so in its arguments.
    public func forkedFromSessionID(arguments: [String], forSessionID sessionID: String) -> String? {
        nil
    }

    /// Nothing, and that is a measured limit rather than an omission. Codex's desktop
    /// application hosts many threads in one process, so a process says nothing about how
    /// many sessions it holds; and its hooks report no process number at all, so a row built
    /// from a process could never be joined to the session it belongs to and would stand
    /// beside it forever. See `docs/agent-integration.md` §1б.
    public func liveSessions() -> [DiscoveredAgentProcess] {
        []
    }

    private static func isDesktopProcess(_ snapshot: ProcessSnapshot) -> Bool {
        guard let executablePath = snapshot.executablePath?.lowercased() else {
            return false
        }
        return executablePath.hasPrefix("/applications/chatgpt.app/")
            || executablePath.hasPrefix("/applications/codex.app/")
    }

    private static func isCLIProcess(_ snapshot: ProcessSnapshot) -> Bool {
        guard let executablePath = snapshot.executablePath?.lowercased() else {
            return false
        }
        let components = URL(fileURLWithPath: executablePath).pathComponents.map { $0.lowercased() }
        return snapshot.executableName.lowercased() == "codex"
            && !components.contains("chatgpt.app")
            && !components.contains("codex.app")
    }
}
