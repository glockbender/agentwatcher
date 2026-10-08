import Foundation

/// The address a desktop client answers with one of its own sessions: its window comes forward
/// showing that session, where raising the application shows whichever one was open.
///
/// Neither address is documented. Both are ones the applications use themselves — Claude.app
/// for its Dock menu — read in their `app.asar` and measured by opening them on Claude.app
/// 2.26454.0 and ChatGPT.app 26.1002.52244 (`docs/session-focus.md`, «Десктопные
/// клиенты»). So a link that stops working is expected one day, and costs the click no more
/// than today's: the application still comes forward.
///
/// An identifier goes into an address only in the shape the application itself checks for.
/// Any other value would be refused there too — but after the window came forward, so the
/// click would look like it had worked.
public enum DesktopSessionLink {
    /// Claude.app, which runs each of its sessions as a Claude Code process of its own.
    public static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    /// ChatGPT.app, which hosts Codex's threads; the bundle kept Codex's identifier when the
    /// two applications became one.
    public static let codexBundleIdentifier = "com.openai.codex"

    /// Claude.app's link to the session a live process's record is about, when that is the
    /// row's own session and Claude.app started it.
    ///
    /// The record has to be of a live process: Claude.app looks the identifier up among its
    /// unarchived sessions and, finding none, opens the start page of Code, and archiving a
    /// session stops its process. And it has to be this row's session: a process number handed
    /// out again could belong to another of Claude.app's sessions by now, with a record of its
    /// own, and the click would land there.
    /// - Parameter sessionLabel: the label the row's process goes by,
    ///   `SessionSnapshot.transcriptLabel`.
    public static func claude(record: ClaudeSessionRecord, sessionLabel: String) -> URL? {
        guard
            record.isDesktopSession,
            record.sessionLabel == sessionLabel,
            let desktopSessionID = record.desktopSessionID
        else {
            return nil
        }
        return claude(desktopSessionID: desktopSessionID)
    }

    /// `claude://code/continue?session=<local_…>`, for the session's identifier inside
    /// Claude.app — `ClaudeSessionRecord.desktopSessionID`, not the session's own identifier.
    public static func claude(desktopSessionID: String) -> URL? {
        guard isClaudeDesktopSessionID(desktopSessionID) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: desktopSessionID)]
        return components.url
    }

    /// `codex://threads/<thread>`, for the thread whose transcript this is.
    ///
    /// The thread's identifier is the session's own, the one that reaches this app only
    /// redacted (ADR-0001) — but the transcript is named after it, and the app found the file
    /// by that name in the first place (`TranscriptLocator`). So nothing new has to cross the
    /// socket. The label is checked again here: a file found for some other row must not send
    /// the click to some other thread.
    public static func codex(transcript: URL, sessionLabel: String) -> URL? {
        guard
            let threadID = TranscriptLocator.sessionIdentifier(
                inFileNamed: transcript.deletingPathExtension().lastPathComponent, source: .codex),
            HookCaptureRedactor.label(forRawIdentifier: threadID) == sessionLabel
        else {
            return nil
        }
        return URL(string: "codex://threads/\(threadID)")
    }

    /// `^local_[A-Za-z0-9-]{1,64}$`, the pattern Claude.app checks the parameter against.
    static func isClaudeDesktopSessionID(_ value: String) -> Bool {
        let prefix = "local_"
        guard value.hasPrefix(prefix) else {
            return false
        }
        let rest = value.dropFirst(prefix.count)
        return (1...64).contains(rest.count)
            && rest.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }
    }
}
