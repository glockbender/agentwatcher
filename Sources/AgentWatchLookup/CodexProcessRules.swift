import AgentWatchCore
import Foundation

/// Codex, as the kernel sees it: a desktop application or a command-line program, and nothing
/// that says which of its sessions a process is.
public struct CodexProcessRules: AgentProcessRules {
    public init() {}

    /// The nearest `codex` above the hook, for a thread in a terminal. Measured on Codex
    /// 0.161.0: a hook of the interactive program is that process's child, as a hook of
    /// `codex exec` is.
    ///
    /// Nothing under the desktop application. It holds every thread in one process, so the
    /// number would be the same for all of them and would close them all together.
    public func agentProcessID(among ancestors: [ProcessSnapshot]) -> Int32? {
        guard !ancestors.contains(where: Self.isDesktopProcess) else {
            return nil
        }
        return ancestors.first(where: Self.isCLIProcess)?.processID
    }

    /// The nearest `codex` above the hook. Measured on Codex 0.153.4: a hook of `codex exec`
    /// is that process's child, or its shell's. Wherever the program is installed — the copy
    /// inside ChatGPT.app runs `codex exec` too — because only a run's hook asks.
    public func headlessRunProcessID(among ancestors: [ProcessSnapshot]) -> Int32? {
        ancestors.first { $0.executableName.lowercased() == "codex" }?.processID
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

    /// Nothing. Codex's desktop application hosts many threads in one process, so a process
    /// says nothing about how many sessions it holds — measured on Codex, version not
    /// recorded. A `codex` in a terminal holds one thread at a time and its hooks name it, but
    /// what would name its thread before any hook has not been looked for. See
    /// `docs/agent-processes.md`, «Почему живой агент находится только у Claude».
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
