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
    /// Asked of a process's arguments and nothing else, so the whole rule can be exercised
    /// without a machine that happens to be running one.
    static func isHelperCommand(_ arguments: [String]) -> Bool {
        // A helper renames itself: `claude bg-pty-host` arrives as one argument, with the
        // job written into the name. A subcommand typed by a person is the next argument
        // instead, so both shapes are read as the same list of words.
        let programWords = (arguments.first ?? "").split(separator: " ").map(String.init)
        let words = Array(programWords.dropFirst()) + arguments.dropFirst()
        guard let subcommand = words.first else {
            return false
        }
        return helperCommands.contains(subcommand)
    }

    private static let helperCommands: Set<String> = ["daemon", "bg-pty-host", "bg-spare"]

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

    /// The words a process was started with, or `nil` when the kernel will not say.
    ///
    /// The executable path cannot answer what `isHelperCommand` asks: every Claude process
    /// on the machine runs the same binary, and only the arguments say whether this one is a
    /// session or one of the agent's own helpers.
    ///
    /// The buffer is laid out as a count, the path the process was executed from, then that
    /// many NUL-separated arguments. The path is skipped rather than returned — it is the
    /// one part of the answer that must not leave this module, the same rule
    /// `ProcessSnapshot` states.
    static func commandArguments(of processID: Int32) -> [String]? {
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard
            sysctl(&managementInformationBase, u_int(managementInformationBase.count), nil, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard
            sysctl(&managementInformationBase, u_int(managementInformationBase.count), &buffer, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else {
            return nil
        }
        let argumentCount = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 {
            index += 1
        }
        while index < size, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        var current: [UInt8] = []
        while index < size, arguments.count < argumentCount {
            if buffer[index] == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return arguments
    }
}
