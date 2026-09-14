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

    /// Resolves the one Codex file read into both facts the sender needs: a human-facing name
    /// when one exists, and whether this is a thread Codex itself indexes at all.
    ///
    /// The latter is deliberately different from having a name. A newly created user thread
    /// can have no `thread_name` yet, while Codex also emits hooks for internal service
    /// sessions that never enter `session_index.jsonl` and must not become widget rows.
    public static func resolveCodexSession(
        payload: JSONValue,
        indexPath: String = SessionDescriptionResolver.codexSessionIndexPath(),
        fileSystem: TitleFileSystem = .live
    ) -> CodexSessionResolution {
        guard
            let sessionID = string("session_id", in: payload),
            let index = fileSystem.readTail(indexPath, codexIndexByteCount)
        else {
            return CodexSessionResolution(isIndexed: false, description: nil)
        }

        let entry = codexSessionEntry(forSessionID: sessionID, inIndex: index)
        let projectName = string("cwd", in: payload).flatMap(projectName(inWorkingDirectory:))
        return CodexSessionResolution(
            isIndexed: entry != nil,
            description: entry.map {
                SessionDescription(title: $0.threadName, projectName: projectName)
            }
        )
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

    /// Claude writes `ai-title`, `gitBranch` and per-turn `usage` into the transcript. One
    /// backward pass reads all three, stopping as soon as each has been answered.
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
        var title: String?
        var branch: String?
        var tokens: Int?

        for fields in objectsNewestFirst(in: tail) {
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
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
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
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .lazy
            .compactMap { line -> [String: JSONValue]? in
                guard
                    let value = try? decoder.decode(JSONValue.self, from: Data(line.utf8)),
                    case let .object(fields) = value
                else {
                    return nil
                }
                return fields
            }
    }

    private static func string(_ key: String, in payload: JSONValue) -> String? {
        guard case let .object(fields) = payload, case let .string(value)? = fields[key] else {
            return nil
        }
        return value
    }
}

/// A Codex hook is admitted only when its raw session ID belongs to a thread in Codex's own
/// index. The optional name is separate because the index can create a thread before naming it.
public struct CodexSessionResolution: Equatable, Sendable {
    public let isIndexed: Bool
    public let description: SessionDescription?

    public init(isIndexed: Bool, description: SessionDescription?) {
        self.isIndexed = isIndexed
        self.description = description
    }
}

private struct CodexIndexEntry {
    let threadName: String?
}

/// The one file read the resolver needs, isolated so tests can exercise the parsing
/// without touching a real home directory.
public struct TitleFileSystem: Sendable {
    public let readTail: @Sendable (String, Int) -> Data?

    public init(readTail: @escaping @Sendable (String, Int) -> Data?) {
        self.readTail = readTail
    }

    public static let live = TitleFileSystem(readTail: { path, byteCount in
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
    })
}
