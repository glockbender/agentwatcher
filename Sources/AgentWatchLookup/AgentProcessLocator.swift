import AgentWatchCore
import Darwin
import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let executableName: String
    /// Read only by the rules that decide which process is an agent's. It is never sent to
    /// Agent Watch.
    public let executablePath: String?

    public init(processID: Int32, executableName: String, executablePath: String? = nil) {
        self.processID = processID
        self.executableName = executableName
        self.executablePath = executablePath
    }
}

/// Asks the kernel about processes, and knows no agent.
///
/// Which process is an agent's, and what it means, is each agent's own rule —
/// `AgentProcessRules`. The entry points the hook sender calls take the agent and ask its
/// rules; everything else here is a question any process can be asked. Executable paths never
/// leave this module (`ProcessSnapshot`): the sender sends a process number and a
/// `SessionClientKind`, never the path they were read from.
public enum AgentProcessLocator {
    /// The process the hook running this code is to name as its session's.
    public static func currentAgentProcessID(for source: AgentSource) -> Int32? {
        source.processRules.agentProcessID(among: ancestorSnapshots())
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
        clientKind(for: source, in: ancestors, argumentsOfProcess: commandArguments(of:))
    }

    /// The same question with the process probe handed in, so a test can state what a
    /// process was started with instead of needing one that really was.
    static func clientKind(
        for source: AgentSource,
        in ancestors: [ProcessSnapshot],
        argumentsOfProcess: (Int32) -> [String]?
    ) -> SessionClientKind? {
        source.processRules.clientKind(among: ancestors, argumentsOfProcess: argumentsOfProcess)
    }

    /// The session the one this hook is about was copied from, when it is a copy — raw, for
    /// the redactor.
    ///
    /// - Parameter sessionID: the session the hook is about, raw, as the payload says it.
    ///   The copy's process runs a second, two-second session first — the one `--resume`
    ///   always leaves behind — and its hooks read the same arguments; only the session the
    ///   process was started for is the copy.
    public static func currentForkedFromSessionID(for source: AgentSource, forSessionID sessionID: String) -> String? {
        let rules = source.processRules
        guard
            let agent = rules.agentProcessID(among: ancestorSnapshots()),
            let arguments = commandArguments(of: agent)
        else {
            return nil
        }
        return rules.forkedFromSessionID(arguments: arguments, forSessionID: sessionID)
    }

    /// A process as the rules look at it, or `nil` when there is no such process.
    static func snapshot(of processID: Int32) -> ProcessSnapshot? {
        snapshot(
            processID: processID,
            executablePath: executablePath(for: processID),
            commandName: commandName(of: processID)
        )
    }

    /// The same answer from what the kernel said. A process it names no path for is still a
    /// process — the agent itself, once an update has deleted the version it runs — and goes
    /// by the name it runs under, which no path rule will take for an agent's.
    static func snapshot(processID: Int32, executablePath: String?, commandName: String?) -> ProcessSnapshot? {
        if let executablePath {
            return ProcessSnapshot(
                processID: processID,
                executableName: URL(fileURLWithPath: executablePath).lastPathComponent,
                executablePath: executablePath
            )
        }
        guard let commandName else {
            return nil
        }
        return ProcessSnapshot(processID: processID, executableName: commandName, executablePath: nil)
    }

    /// A process and its ancestors, nearest first.
    static func ancestorSnapshots(startingAt first: Int32 = getppid()) -> [ProcessSnapshot] {
        ancestorSnapshots(startingAt: first, snapshotOf: snapshot(of:), parentOf: parentProcessID(of:))
    }

    /// The same walk with the kernel handed in. It stops where there is no process, not where
    /// there is no path: it used to stop at the first process the kernel named no path for,
    /// and past a deleted version that was the agent itself.
    static func ancestorSnapshots(
        startingAt first: Int32,
        snapshotOf: (Int32) -> ProcessSnapshot?,
        parentOf: (Int32) -> Int32?
    ) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var processID = first

        for _ in 0..<16 {
            guard processID > 1 else {
                break
            }
            guard let snapshot = snapshotOf(processID) else {
                break
            }

            result.append(snapshot)
            guard let parentProcessID = parentOf(processID), parentProcessID != processID else {
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
    /// Public because the app needs it for a question the sender never asks: a session
    /// remembered from a previous launch names a PID, and macOS reuses those. A process that
    /// started after the session's last event is somebody else's.
    public static func startTime(of processID: Int32) -> Date? {
        guard let process = kernelRecord(of: processID) else {
            return nil
        }
        let startedAt = process.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(startedAt.tv_sec) + Double(startedAt.tv_usec) / 1_000_000
        )
    }

    /// The name a process runs under, as the kernel keeps it (at most 16 bytes), or `nil` when
    /// there is no such process.
    static func commandName(of processID: Int32) -> String? {
        guard var process = kernelRecord(of: processID) else {
            return nil
        }
        return withUnsafeBytes(of: &process.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The parent of a process, or `nil` when there is no such process.
    ///
    /// Public because the app walks the same tree to find the window a session belongs to,
    /// and two copies of a `sysctl` call is two places to get the struct layout wrong.
    public static func parentProcessID(of processID: Int32) -> Int32? {
        kernelRecord(of: processID)?.kp_eproc.e_ppid
    }

    /// What became of the terminal a process was started in.
    public enum TerminalState: Equatable, Sendable {
        /// The process still has its controlling terminal.
        case attached
        /// It had one, and the terminal went away while the process stayed.
        ///
        /// Measured on Claude Code 2.1.270 and 2.1.280 in a JetBrains terminal tab: after the
        /// tab was closed the IDE still held the pty open, the agent's shutdown waited in
        /// `tcsetattr` for output nothing drained, and neither `SIGTERM` nor `SIGKILL` got it
        /// past that wait. `docs/agent-integration.md` has the reproduction.
        case lost
        /// It never had one — an application, or a child given a pty only for its output.
        case neverHad
    }

    /// Whether a process still has the terminal it was started in, or `nil` when there is
    /// no such process.
    public static func terminalState(of processID: Int32) -> TerminalState? {
        guard let process = kernelRecord(of: processID) else {
            return nil
        }
        return terminalState(
            controlsATerminal: process.kp_proc.p_flag & P_CONTROLT != 0,
            terminalDevice: process.kp_eproc.e_tdev
        )
    }

    /// The same answer from the two fields it is read from, so the rule can be checked
    /// against the values measured without a process that happens to be in that state.
    ///
    /// Both fields, because neither says it alone. The kernel clears the device when the
    /// terminal's session ends but leaves the flag, which is set only on a process that once
    /// had a controlling terminal — so a missing device on its own is every application.
    static func terminalState(controlsATerminal: Bool, terminalDevice: dev_t) -> TerminalState {
        guard controlsATerminal else {
            return .neverHad
        }
        return terminalDevice == noDevice ? .lost : .attached
    }

    /// `NODEV` from `<sys/param.h>`, which Swift does not import: the macro is a cast.
    private static let noDevice: dev_t = -1

    /// The terminal device a process reads and writes through, from its own standard
    /// descriptors, or `nil` when none of them is one.
    ///
    /// Not the kernel's record of the controlling terminal: for the one case this is asked
    /// about — a terminal that was lost — that record is exactly what has been cleared,
    /// while the descriptors still hold the device open.
    public static func terminalDevicePath(of processID: Int32) -> String? {
        for descriptor: Int32 in 0...2 {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(processID, descriptor, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                continue
            }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if path.hasPrefix("/dev/tty") {
                return path
            }
        }
        return nil
    }

    /// The kernel's record of a process, or `nil` when there is no such process.
    ///
    /// One call answers both questions, which is why it is one call. A PID nobody holds makes
    /// `sysctl` succeed and fill in nothing, so the returned size is what tells a record apart
    /// from "no such process" — checking only the result would read a zeroed struct as a
    /// process that started in 1970 with parent 0.
    private static func kernelRecord(of processID: Int32) -> kinfo_proc? {
        var process = kinfo_proc()
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var size = MemoryLayout<kinfo_proc>.size
        guard
            sysctl(&managementInformationBase, u_int(managementInformationBase.count), &process, &size, nil, 0) == 0,
            size > 0
        else {
            return nil
        }
        return process
    }

    /// The directory a process is working in.
    ///
    /// The full path, which is why it is here and not beside the scanner's
    /// `workingDirectoryName`: that one trims to the last component because its answer goes
    /// into an event, and ADR-0001 lets a project name cross that boundary
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
    /// The executable path cannot answer what `ClaudeProcessRules.isHelperCommand` asks: every Claude process
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
