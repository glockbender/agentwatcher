import AgentWatchCore
import Darwin
import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let executableName: String
    /// Used only while resolving the local Claude process. It is never sent to Agent Watch.
    public let executablePath: String?

    public init(processID: Int32, executableName: String, executablePath: String? = nil) {
        self.processID = processID
        self.executableName = executableName
        self.executablePath = executablePath
    }
}

/// Finds the long-lived Claude process that launched a short-lived hook command.
/// Only the selected numeric PID is sent to Agent Watch; executable paths never leave this helper.
public enum AgentProcessLocator {
    public static func currentClaudeProcessID() -> Int32? {
        findClaudeProcessID(in: ancestorSnapshots())
    }

    public static func findClaudeProcessID(in ancestors: [ProcessSnapshot]) -> Int32? {
        ancestors.first(where: isClaudeProcess)?.processID
    }

    /// Returns a host kind only when process ancestry makes it trustworthy.
    /// Executable paths stay in this process; the ingress protocol receives the
    /// resulting enum value only.
    public static func currentClientKind(for source: AgentSource) -> SessionClientKind? {
        clientKind(for: source, in: ancestorSnapshots())
    }

    public static func clientKind(
        for source: AgentSource,
        in ancestors: [ProcessSnapshot]
    ) -> SessionClientKind? {
        if source == .codex, ancestors.contains(where: isCodexDesktopProcess) {
            return .desktop
        }

        switch source {
        case .claude:
            return ancestors.contains(where: isClaudeProcess) ? .cli : nil
        case .codex:
            return ancestors.contains(where: isCodexCLIProcess) ? .cli : nil
        }
    }

    /// Whether this process is the Claude CLI itself.
    ///
    /// Internal rather than private: the scanner asks the same question of every process on
    /// the machine, and two answers to "what is a Claude process" would drift apart.
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

    private static func isCodexDesktopProcess(_ snapshot: ProcessSnapshot) -> Bool {
        guard let executablePath = snapshot.executablePath?.lowercased() else {
            return false
        }
        return executablePath.hasPrefix("/applications/chatgpt.app/")
            || executablePath.hasPrefix("/applications/codex.app/")
    }

    private static func isCodexCLIProcess(_ snapshot: ProcessSnapshot) -> Bool {
        guard let executablePath = snapshot.executablePath?.lowercased() else {
            return false
        }
        let components = URL(fileURLWithPath: executablePath).pathComponents.map { $0.lowercased() }
        return snapshot.executableName.lowercased() == "codex"
            && !components.contains("chatgpt.app")
            && !components.contains("codex.app")
    }

    private static func ancestorSnapshots() -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var processID = getppid()

        for _ in 0..<16 {
            guard processID > 1 else {
                break
            }
            guard let executablePath = executablePath(for: processID) else {
                break
            }

            result.append(
                ProcessSnapshot(
                    processID: processID,
                    executableName: URL(fileURLWithPath: executablePath).lastPathComponent,
                    executablePath: executablePath
                ))
            guard let parentProcessID = parentProcessID(of: processID), parentProcessID != processID else {
                break
            }
            processID = parentProcessID
        }

        return result
    }

    /// The executable behind a process number, or `nil` when the kernel will not say.
    ///
    /// Internal for the scanner, which asks it of every process rather than of an ancestor
    /// chain. The path itself never leaves this module — see `ProcessSnapshot`.
    static func executablePath(for processID: Int32) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(processID, &path, UInt32(path.count)) > 0 else {
            return nil
        }
        let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    /// When a process started, or `nil` when there is no such process.
    ///
    /// One call answers both questions, which is why it is one call. A PID nobody holds makes
    /// `sysctl` succeed and fill in nothing, so the returned size is what tells "started then"
    /// apart from "no such process" — checking only the result would read a zeroed struct as a
    /// process that started in 1970.
    ///
    /// Public because the app needs it for a question the sender never asks: a session
    /// remembered from a previous launch names a PID, and macOS reuses those. A process that
    /// started after the session's last event is somebody else's.
    public static func startTime(of processID: Int32) -> Date? {
        var process = kinfo_proc()
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var size = MemoryLayout<kinfo_proc>.size
        guard
            sysctl(&managementInformationBase, u_int(managementInformationBase.count), &process, &size, nil, 0) == 0,
            size > 0
        else {
            return nil
        }
        let startedAt = process.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(startedAt.tv_sec) + Double(startedAt.tv_usec) / 1_000_000
        )
    }

    /// The parent of a process, or `nil` when the kernel will not say.
    ///
    /// Public because the app walks the same tree to find the window a session belongs to,
    /// and two copies of a `sysctl` call is two places to get the struct layout wrong.
    /// The `size` check is the same one `startTime` explains and for the same reason: a PID
    /// nobody holds makes `sysctl` succeed and write nothing, so without it a dead process
    /// answers "parent 0" — a number, where the caller asked a question that has no answer.
    public static func parentProcessID(of processID: Int32) -> Int32? {
        var process = kinfo_proc()
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var size = MemoryLayout<kinfo_proc>.size
        guard
            sysctl(&managementInformationBase, u_int(managementInformationBase.count), &process, &size, nil, 0) == 0,
            size > 0
        else {
            return nil
        }
        return process.kp_eproc.e_ppid
    }

    /// The directory a process is working in.
    ///
    /// The full path, which is why it is here and not beside the scanner's
    /// `workingDirectoryName`: that one trims to the last component because its answer goes
    /// into an event, and `docs/architecture.md` §15 lets a project name cross that boundary
    /// and no path with it. This answer crosses nothing — the app asks it about a process on
    /// the same machine, matches it against the projects an IDE already lists, and keeps
    /// only the name it found.
    public static func workingDirectoryPath(of processID: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard read == Int32(size) else {
            return nil
        }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }
}
