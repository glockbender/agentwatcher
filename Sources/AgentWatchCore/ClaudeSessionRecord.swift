import Foundation

/// Which process one of Claude Code's own records is about: `~/.claude/sessions/<pid>.json`,
/// written for a process while it runs. Measured, not documented — `docs/agent-processes.md`,
/// «Почему живой агент находится только у Claude».
///
/// Two readers need exactly this: the viewer of a background job, and the rule that knows an
/// agent's process by its record rather than by its path. A number handed out again has to be
/// told from the original the same way for both, which is why the comparison lives here too.
public struct ClaudeSessionRecord: Equatable, Sendable {
    public let processID: Int32
    /// When the process started, as the record says, or `nil` when it does not.
    public let startedAt: Date?
    /// The session the process runs, raw. Read only on this side of the socket, to be compared
    /// with a row's label — it names a transcript (ADR-0001).
    public let sessionID: String?
    /// Whether Claude.app started this process for one of its sessions: `entrypoint` is
    /// `claude-desktop`. Measured on all four such processes on Claude Code 2.1.289; the eleven
    /// sessions typed into terminals said `cli`. A `claude` typed into Claude.app's own
    /// terminal pane was not measured, and is expected to say `cli` as well.
    public let isDesktopSession: Bool
    /// Whether a program runs this session with no conversation window: `entrypoint` is
    /// `sdk-cli` (`claude -p`), `sdk-ts` or `sdk-py` (the Agent SDK). Measured for `sdk-cli`
    /// on Claude Code 2.1.293. The field is the `CLAUDE_CODE_ENTRYPOINT` a process was started
    /// with, and a child inherits its parent's: `claude -p` run from a Claude.app session
    /// wrote `claude-desktop`. So `-p` is read from the arguments first
    /// (`ClaudeProcessRules.clientKind`), and this is what is left for a run without it.
    public let isHeadlessRun: Bool
    /// The session's identifier inside Claude.app — `hostSessionId`, `local_…` — which is not
    /// the session's own identifier and is what the app's link takes. Only read for a session
    /// Claude.app started: the field means "the host's name for me", and another host would
    /// name it in a scheme of its own.
    public let desktopSessionID: String?

    /// How far the record's start may be from the kernel's and still be the same process. The
    /// kernel's own reading in the record matched `ps` to the second on the three records
    /// compared; Claude Code's clock is 0–3 s later.
    public static let startTolerance: TimeInterval = 60

    private static let headlessEntrypoints: Set<String> = ["sdk-cli", "sdk-ts", "sdk-py"]

    public init?(data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        self.init(record: record)
    }

    init?(record: [String: Any]) {
        guard let processID = Self.processID(in: record) else {
            return nil
        }
        self.processID = processID
        self.startedAt = Self.startedAt(in: record)
        self.sessionID = record["sessionId"] as? String
        self.isDesktopSession = record["entrypoint"] as? String == "claude-desktop"
        self.isHeadlessRun = (record["entrypoint"] as? String).map(Self.headlessEntrypoints.contains) ?? false
        self.desktopSessionID = isDesktopSession ? record["hostSessionId"] as? String : nil
    }

    /// Whether a record's start and the kernel's are one process's, rather than a number the
    /// kernel handed to somebody else after the recorded process went.
    public static func starts(_ recorded: Date, match kernel: Date) -> Bool {
        abs(kernel.timeIntervalSince(recorded)) < startTolerance
    }

    /// The record's start of the process: the kernel's own reading first (`procStart`, the
    /// spelling of `ps -o lstart` — `Sat Sep 12 09:53:31 2026`, a single-digit day padded with
    /// a space — in UTC, measured three hours behind the local `ps` on eight records), and
    /// Claude Code's clock (`startedAt`, milliseconds since 1970, 0–3 s later on the same
    /// records) for a record without it. The kernel's is exact and nothing rewrites it.
    private static func startedAt(in record: [String: Any]) -> Date? {
        if let text = record["procStart"] as? String,
            let date = kernelStartFormatter.date(from: text.split(separator: " ").joined(separator: " "))
        {
            return date
        }
        guard let milliseconds = record["startedAt"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static let kernelStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// The number as Claude Code writes it, a number, and in the quoted spelling older records
    /// used.
    private static func processID(in record: [String: Any]) -> Int32? {
        if let number = record["pid"] as? Int, let processID = Int32(exactly: number) {
            return processID
        }
        if let text = record["pid"] as? String {
            return Int32(text)
        }
        return nil
    }
}
