import Foundation

/// Finds the file a session writes, without a path ever crossing the socket.
///
/// The app knows a session only by its label, and a label is the session's own identifier put
/// through the redaction twice — see `HookCaptureRedactor.label(forRawIdentifier:)`. Both
/// agents happen to name a transcript after that same identifier, so the app can put every
/// file name it finds through the same function and look for its own label. Nothing is asked
/// of the sender and nothing new is accepted over the socket, which matters because anything
/// on this machine can connect to it: a field carrying a path would be a field telling the app
/// which file to open.
///
/// The cost of being told instead of looking is a convention this makes an assumption about.
/// If either agent renames its transcripts, or `CLAUDE_CONFIG_DIR` moves the root, nothing is
/// found — and that is a reported failure rather than wrong data, which is the property that
/// makes the assumption acceptable. `docs/architecture.md` §15 records when to revisit it.
public enum TranscriptLocator {
    public static func defaultRoot(for source: AgentSource, home: URL) -> URL {
        switch source {
        case .claude:
            home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex:
            home.appendingPathComponent(".codex/sessions", isDirectory: true)
        }
    }

    /// Where Codex keeps the name of every thread: one short record each, beside the sessions
    /// directory rather than inside it.
    ///
    /// Derived from the root the caller is already using, so a moved `CODEX_HOME` takes the
    /// index with it instead of leaving one of the two behind.
    public static func codexThreadIndex(inRoot root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    /// The transcript for one session, or `nil` when no file's name matches.
    ///
    /// Every name is hashed and compared; nothing is opened and nothing is read. Enumerating
    /// a root took 23 ms for 207 files and 3 ms for 236 when this was written, and it grows
    /// with a person's history, so a caller runs it when a session appears rather than on a
    /// tick — and off the main thread.
    public static func locate(
        sessionLabel: String,
        source: AgentSource,
        root: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard
                let identifier = sessionIdentifier(
                    inFileNamed: url.deletingPathExtension().lastPathComponent, source: source)
            else {
                continue
            }
            if HookCaptureRedactor.label(forRawIdentifier: identifier) == sessionLabel {
                return url
            }
        }
        return nil
    }

    /// The session identifier a transcript is named after, or `nil` for a file that is not one.
    ///
    /// Claude names the file after the identifier alone. Codex prefixes a timestamp, so the
    /// identifier is the trailing part — matched by shape rather than by counting separators,
    /// because the timestamp contains separators of its own. A Claude subagent writes an
    /// `agent-…` file that is deliberately no session's transcript and fails the shape.
    public static func sessionIdentifier(inFileNamed name: String, source: AgentSource) -> String? {
        switch source {
        case .claude:
            return isUUIDShaped(name) ? name : nil
        case .codex:
            let candidate = String(name.suffix(36))
            return isUUIDShaped(candidate) ? candidate : nil
        }
    }

    /// `8-4-4-4-12` hexadecimal. Not `UUID(uuidString:)`: Codex identifiers are UUID-shaped
    /// but not all of them are valid UUIDs by version, and rejecting one on that ground would
    /// lose a session for a reason that has nothing to do with finding its file.
    private static func isUUIDShaped(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else {
            return false
        }
        let lengths = [8, 4, 4, 4, 12]
        for (group, length) in zip(groups, lengths) {
            guard group.count == length, group.allSatisfy(\.isHexDigit) else {
                return false
            }
        }
        return true
    }
}
