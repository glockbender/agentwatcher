import AgentWatchCore
import Foundation

/// Reads what a session says about itself in its own files.
///
/// Both processes ask, and they reach the files by different routes. The hook process holds
/// the raw `session_id`, `cwd` and `transcript_path` — all three are redacted before anything
/// reaches the socket, so only the resolved values travel, and of the working directory only
/// its last component (ADR-0001). The app never receives a path and finds
/// the transcript itself through `TranscriptLocator`. The rules for reading one live here
/// once so that the name a session shows does not depend on which side looked.
///
/// Every step is fail-open. The on-disk shapes below are undocumented internals of Claude
/// Code and Codex — they have changed before — so a missing file or an unfamiliar layout
/// must degrade to "not known", never to an error or a stall.
public enum SessionDescriptionResolver {
    /// Claude rewrites these records on most turns, so a tail is enough and a full read of a
    /// multi-megabyte transcript is never warranted inside the sender's deadline.
    ///
    /// The window is generous on purpose. Measured across eight recent transcripts, the last
    /// title sat between 0.5 KB and 30 KB from the end — one large tool result past it would
    /// have pushed it out of a 64 KB window, and the session would then have shown the
    /// generic fallback name with nothing to explain it.
    ///
    /// Reading it costs nothing worth protecting: a sender invocation that reads the tail of
    /// an 85 MB transcript and one that opens no file at all both take 0.77 s, which is
    /// process start-up and nothing else. So this runs on every event rather than only on
    /// turn boundaries — a session already running when the widget starts would otherwise
    /// keep a placeholder name until its next turn ended.
    public static let transcriptTailByteCount = 256 * 1024
    /// Unlike transcripts, this is one small metadata record per Codex thread. Membership is
    /// an admission check, not a best-effort title lookup: overlooking an old record would
    /// silently hide an otherwise valid user session. `readTail` receives this maximum value
    /// and consequently starts at byte zero for every representable file size.
    static let codexIndexByteCount = Int.max
    /// Measured on Codex 0.162.0-alpha.2: a transcript opens with `session_meta`, which carries
    /// the instructions the thread started with, 23 KB on this machine. A window that ends
    /// before that record's newline reads as a record not yet written.
    static let codexSessionMetaByteCount = 64 * 1024

    public static func resolve(
        source: AgentSource,
        payload: JSONValue,
        codexIndexPath: String = SessionDescriptionResolver.codexSessionIndexPath(),
        fileSystem: TitleFileSystem = .live
    ) -> SessionDescription? {
        // The working directory is in the hook payload for both agents, so its name costs no
        // file read at all.
        let projectName = string("cwd", in: payload).flatMap(projectName(inWorkingDirectory:))

        let described =
            switch source {
            case .claude: claudeDescription(payload: payload, fileSystem: fileSystem)
            case .codex: codexDescription(payload: payload, indexPath: codexIndexPath, fileSystem: fileSystem)
            }

        let description = SessionDescription(
            title: described?.title,
            projectName: projectName,
            gitBranch: described?.gitBranch,
            contextInputTokens: described?.contextInputTokens
        )
        return description.isEmpty ? nil : description
    }

    /// Resolves the Codex file reads into both facts the sender needs: a human-facing name
    /// when one exists, and whether this is a thread a person started at all.
    ///
    /// The latter is deliberately different from having a name, and from being in
    /// `session_index.jsonl`. Measured on Codex 0.162.0-alpha.2: ChatGPT.app writes a new
    /// thread there only once the thread is named, seconds into its first turn, and that
    /// turn's first hooks come earlier. Its transcript exists by then and opens with a record
    /// saying who started it, so a thread missing from the index is admitted when that record
    /// says a person did.
    ///
    /// What must stay out is the internal session ChatGPT.app runs to name the thread. It has
    /// no transcript (`transcript_path` is null), so only the index could admit it, and it
    /// never enters the index.
    ///
    /// A `codex exec` run is admitted as a headless one: the app decides whether to show it.
    public static func resolveCodexSession(
        payload: JSONValue,
        indexPath: String = SessionDescriptionResolver.codexSessionIndexPath(),
        fileSystem: TitleFileSystem = .live
    ) -> CodexSessionResolution {
        guard let sessionID = string("session_id", in: payload) else {
            return CodexSessionResolution(isAdmitted: false, description: nil)
        }
        let projectName = string("cwd", in: payload).flatMap(projectName(inWorkingDirectory:))

        if let index = fileSystem.readTail(indexPath, codexIndexByteCount),
            let entry = codexSessionEntry(forSessionID: sessionID, inIndex: index)
        {
            return CodexSessionResolution(
                isAdmitted: true,
                description: SessionDescription(title: entry.threadName, projectName: projectName)
            )
        }
        guard
            let transcriptPath = string("transcript_path", in: payload),
            let starter = codexThreadStarter(transcriptPath: transcriptPath, fileSystem: fileSystem)
        else {
            return CodexSessionResolution(isAdmitted: false, description: nil)
        }
        return CodexSessionResolution(
            isAdmitted: true,
            isHeadlessRun: starter == .headlessRun,
            description: SessionDescription(title: nil, projectName: projectName)
        )
    }

    /// Who started a Codex thread a person is behind, as its transcript's first record says.
    enum CodexThreadStarter: Equatable {
        /// In a window: the terminal or the desktop application.
        case person
        /// `codex exec`, measured on Codex 0.153.4 to say `source: "exec"` and
        /// `originator: "codex_exec"` with `thread_source` still `user`. None of these enters
        /// the index.
        case headlessRun
    }

    /// How the transcript's `session_meta` says the thread started, when a person is behind it.
    ///
    /// Anything short of that answers `nil`: a file not there yet, a first record still being
    /// written, an older Codex whose record has no `thread_source`. Each of those leaves the
    /// session to the index alone, so a failure here can delay a row, never add one.
    static func codexThreadStarter(transcriptPath: String, fileSystem: TitleFileSystem) -> CodexThreadStarter? {
        guard
            let head = fileSystem.readHead(transcriptPath, codexSessionMetaByteCount),
            let newline = head.firstIndex(of: UInt8(ascii: "\n")),
            let record = try? JSONDecoder().decode(JSONValue.self, from: head[head.startIndex..<newline]),
            case let .object(fields) = record,
            case .string("session_meta")? = fields["type"],
            case let .object(meta)? = fields["payload"],
            // Subagents say `subagent`, the reviewer of approval requests `guardian_review`.
            case .string("user")? = meta["thread_source"]
        else {
            return nil
        }
        if case .string("exec")? = meta["source"] {
            return .headlessRun
        }
        return .person
    }

    /// The directory's own name. The path that leads to it never leaves this process.
    static func projectName(inWorkingDirectory path: String) -> String? {
        // The empty string is refused before `URL` sees it: `URL(fileURLWithPath: "")`
        // resolves against the current directory, so an absent `cwd` would have been
        // reported as whatever directory the hook process happened to start in.
        guard !path.isEmpty else {
            return nil
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Claude writes the session's name, `gitBranch` and per-turn `usage` into the transcript.
    /// One backward pass reads all three, stopping as soon as each has been answered.
    static func claudeDescription(payload: JSONValue, fileSystem: TitleFileSystem) -> SessionDescription? {
        guard
            let transcriptPath = string("transcript_path", in: payload),
            let tail = fileSystem.readTail(transcriptPath, transcriptTailByteCount)
        else {
            return nil
        }
        return claudeDescription(inTranscriptTail: tail)
    }

    public static func claudeDescription(inTranscriptTail tail: Data) -> SessionDescription {
        let lines = linesNewestFirst(in: tail)
        var title = customTitle(inLinesNewestFirst: lines)
        var branch: String?
        var tokens: Int?

        for fields in lines.lazy.compactMap(object(inLine:)) {
            if title == nil, case .string("ai-title")? = fields["type"], case let .string(value)? = fields["aiTitle"] {
                title = value
            }
            if branch == nil, case let .string(value)? = fields["gitBranch"], !value.isEmpty {
                branch = value
            }
            if tokens == nil, let usage = contextInputTokens(inMessage: fields["message"]) {
                tokens = usage
            }
            if title != nil, branch != nil, tokens != nil {
                break
            }
        }
        return SessionDescription(title: title, gitBranch: branch, contextInputTokens: tokens)
    }

    /// The name a person gave the session with `/rename` or `claude --name`. Claude Code puts
    /// it above its own `ai-title`, in the terminal tab and in `/resume`, so the widget does
    /// too — and it is the only name a session has when Claude Code generates none.
    ///
    /// Only the newest record counts: an empty one is how a name is taken back, and the name
    /// it replaced must not come back. Lines are matched as text before any is decoded, the
    /// way Claude Code finds this record itself: a session nobody named has none, and proving
    /// that by decoding would cost a decode of every line in the tail on every event.
    private static func customTitle(inLinesNewestFirst lines: [Substring]) -> String? {
        let newest = lines.lazy
            .filter { $0.contains(#""custom-title""#) }
            .compactMap(object(inLine:))
            .first { fields in
                if case .string("custom-title")? = fields["type"] { true } else { false }
            }
        guard
            case let .string(name)? = newest?["customTitle"],
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return name
    }

    /// Everything the last turn carried into the model: fresh input, what was read from the
    /// cache, and what was written to it. Output tokens are deliberately left out — they are
    /// what came back, not what the window is holding.
    static func contextInputTokens(inMessage message: JSONValue?) -> Int? {
        guard
            case let .object(fields)? = message,
            case let .object(usage)? = fields["usage"]
        else {
            return nil
        }
        // Every conversion is checked. `Int(1e30)` traps, and so does a sum that overflows —
        // and a trap here kills the hook process, which is the one thing this whole file is
        // written to avoid. A transcript is a file on disk that anything can write to.
        var total = 0
        for key in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
            guard case let .number(value)? = usage[key] else {
                continue
            }
            guard value >= 0, value <= Double(SessionDescription.maximumContextInputTokens) else {
                return nil
            }
            let (sum, overflowed) = total.addingReportingOverflow(Int(value))
            guard !overflowed, sum <= SessionDescription.maximumContextInputTokens else {
                return nil
            }
            total = sum
        }
        return total > 0 ? total : nil
    }

    /// Codex keeps one line per thread in a small index file; later lines supersede earlier
    /// ones. It carries no branch and no token counts.
    static func codexDescription(
        payload: JSONValue,
        indexPath: String,
        fileSystem: TitleFileSystem
    ) -> SessionDescription? {
        resolveCodexSession(payload: payload, indexPath: indexPath, fileSystem: fileSystem).description
    }

    private static func codexSessionEntry(forSessionID sessionID: String, inIndex index: Data) -> CodexIndexEntry? {
        for fields in objectsNewestFirst(in: index) {
            if case .string(sessionID)? = fields["id"] {
                let threadName: String?
                if case let .string(name)? = fields["thread_name"] {
                    threadName = name
                } else {
                    threadName = nil
                }
                return CodexIndexEntry(threadName: threadName)
            }
        }
        return nil
    }

    /// Honours `CODEX_HOME` because Codex itself does; hardcoding `~/.codex` would leave
    /// anyone who moved it with no title and no explanation.
    public static func codexSessionIndexPath() -> String {
        let home =
            ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? AgentFolders.defaultFolder(for: .codex, home: AgentWatchPaths.homeDirectory())
        return home.appendingPathComponent("session_index.jsonl").path
    }

    /// The records of a JSON-lines tail, newest first, with the unreadable ones skipped.
    ///
    /// Two details matter. The bytes are decoded with `String(decoding:as:)`, not
    /// `String(data:encoding:)`: a tail can begin in the middle of a multi-byte character —
    /// routine for Cyrillic or emoji — and the strict initialiser would return nothing for
    /// the whole buffer, defeating the per-line recovery. And a partial tail read slices its
    /// first line in half, so an unparsable line is skipped rather than treated as the end
    /// of useful data.
    ///
    /// Lazy, so a caller that finds what it wants in the last few lines pays for those and
    /// stops.
    private static func objectsNewestFirst(in data: Data) -> some Sequence<[String: JSONValue]> {
        linesNewestFirst(in: data).lazy.compactMap(object(inLine:))
    }

    private static func linesNewestFirst(in data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
    }

    private static func object(inLine line: Substring) -> [String: JSONValue]? {
        guard
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
            case let .object(fields) = value
        else {
            return nil
        }
        return fields
    }

    private static func string(_ key: String, in payload: JSONValue) -> String? {
        guard case let .object(fields) = payload, case let .string(value)? = fields[key] else {
            return nil
        }
        return value
    }
}

/// A Codex hook is admitted only when it is about a thread a person started. The optional
/// name is separate because a thread can be admitted before it is named.
public struct CodexSessionResolution: Equatable, Sendable {
    public let isAdmitted: Bool
    /// A `codex exec` run: its row is `SessionClientKind.headless`.
    public let isHeadlessRun: Bool
    public let description: SessionDescription?

    public init(isAdmitted: Bool, isHeadlessRun: Bool = false, description: SessionDescription?) {
        self.isAdmitted = isAdmitted
        self.isHeadlessRun = isHeadlessRun
        self.description = description
    }
}

private struct CodexIndexEntry {
    let threadName: String?
}

/// The file reads the resolver needs, isolated so tests can exercise the parsing without
/// touching a real home directory.
public struct TitleFileSystem: Sendable {
    public let readTail: @Sendable (String, Int) -> Data?
    public let readHead: @Sendable (String, Int) -> Data?

    public init(
        readTail: @escaping @Sendable (String, Int) -> Data?,
        readHead: @escaping @Sendable (String, Int) -> Data? = { _, _ in nil }
    ) {
        self.readTail = readTail
        self.readHead = readHead
    }

    public static let live = TitleFileSystem(
        readTail: { path, byteCount in
            guard byteCount > 0, let handle = FileHandle(forReadingAtPath: path) else {
                return nil
            }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else {
                return nil
            }
            // Unsigned arithmetic: subtracting from a file shorter than the window would wrap.
            let offset = end > UInt64(byteCount) ? end - UInt64(byteCount) : 0
            guard (try? handle.seek(toOffset: offset)) != nil else {
                return nil
            }
            return try? handle.readToEnd()
        },
        readHead: { path, byteCount in
            guard byteCount > 0, let handle = FileHandle(forReadingAtPath: path) else {
                return nil
            }
            defer { try? handle.close() }
            return try? handle.read(upToCount: byteCount)
        }
    )
}
