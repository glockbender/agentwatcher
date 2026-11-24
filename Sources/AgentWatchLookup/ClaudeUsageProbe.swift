import AgentWatchCore
import Darwin
import Foundation

/// Asks Claude Code for the plan's usage by starting it once, headless, for about two seconds.
///
/// The run sends no prompt and spends no tokens: it writes one `get_usage` control request to
/// Claude Code's standard input, reads the reply, closes the input and Claude Code exits on its
/// own. It still counts as a Claude Code session in the organisation's OpenTelemetry metrics,
/// which is why `ClaudeUsageProbePolicy` decides when it may run (ADR-0026). Measured on Claude
/// Code 2.1.326: the reply after 0.85–1.1 s, the exit after 1.8 s.
///
/// The words are the ones a third-party menu bar app already runs this with: no tools, no MCP
/// servers, no settings of the person's and no hooks, so the run pulls nothing of theirs in
/// and none of the app's own hooks report it as a session.
public enum ClaudeUsageProbe {
    public static let arguments = [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--no-session-persistence", "--tools", "", "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
        "--settings", #"{"disableAllHooks":true}"#,
    ]

    /// Ten times what one run takes, and well short of the next tick that could start another.
    public static let defaultTimeout: TimeInterval = 10

    /// Starts `executable`, asks, and returns what it said; `nil` when nothing usable came back
    /// in time — it did not start, exited first, or the time ran out.
    ///
    /// Blocks for as long as the run takes, so a caller on the main thread hands it off.
    ///
    /// - Parameters:
    ///   - executable: the agent `AgentInstallationLookup` found, never one inside an
    ///     application bundle: launching that one is what raises Gatekeeper on the screen.
    ///   - home: the home Claude Code keeps `.claude.json` in. Passed as `HOME`, which is the
    ///     one variable it follows to find its own files.
    public static func ask(
        executable: String,
        home: URL,
        workingDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: TimeInterval = defaultTimeout,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClaudeUsageSnapshot.Reply? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment(home: home, executable: executable)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let requestID = UUID().uuidString
        let reader = ReplyReader(requestID: requestID, now: now)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                reader.finish()
            } else {
                reader.append(data)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // A Claude Code that exited before reading would otherwise kill the app with SIGPIPE:
        // nothing in it ignores the signal, and the write is to a pipe, not a socket.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForWriting.write(contentsOf: ClaudeUsageSnapshot.request(id: requestID))
        let deadline = DispatchTime.now() + timeout
        _ = reader.wait(until: deadline)
        // Closing the input is what makes Claude Code exit; the deadline is for one that does not.
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: max(deadline, .now() + 2)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        return reader.reply
    }

    /// Only what Claude Code needs to find its own files, its sign-in and, when it was
    /// installed with npm, the Node it starts through `#!/usr/bin/env node`. An app started
    /// from Finder has little more than this, and nothing a shell profile exports belongs in a
    /// run the person did not start.
    ///
    /// `PATH` leads with the agent's own directory: npm, nvm, Volta and Bun put `node` beside
    /// the `claude` they installed, and Homebrew's Node lives in the two directories after it.
    static func environment(home: URL, executable: String) -> [String: String] {
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let path = [directory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var environment = ["HOME": home.path, "PATH": path.joined(separator: ":")]
        let inherited = ProcessInfo.processInfo.environment
        for name in ["USER", "LOGNAME", "TMPDIR"] {
            environment[name] = inherited[name]
        }
        return environment
    }
}

/// Collects output a line at a time until the reply to one request turns up.
private final class ReplyReader: @unchecked Sendable {
    private let requestID: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var answer: ClaudeUsageSnapshot.Reply?
    private var signalled = false

    init(requestID: String, now: @escaping @Sendable () -> Date) {
        self.requestID = requestID
        self.now = now
    }

    var reply: ClaudeUsageSnapshot.Reply? {
        lock.withLock { answer }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard answer == nil else {
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let reply = ClaudeUsageSnapshot.reply(in: Data(line), requestID: requestID, now: now())
                if reply != .unrecognised {
                    answer = reply
                    signalLocked()
                    return
                }
            }
        }
    }

    func finish() {
        lock.withLock { signalLocked() }
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        done.wait(timeout: deadline)
    }

    private func signalLocked() {
        guard !signalled else {
            return
        }
        signalled = true
        done.signal()
    }
}
