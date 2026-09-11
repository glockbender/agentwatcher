import Foundation

/// A path a shell will read as exactly one word.
///
/// Both agents run a hook command through a shell, and the sender lives in
/// `~/Library/Application Support/AgentWatch/` — a path with a space in it. Written plainly
/// that command is two words: measured live, `/bin/sh` tried to run
/// `/Users/…/Library/Application` and answered `No such file or directory`, exit 127. Every
/// hook failed, and because a failing hook is fail-open by design, nothing said so — the
/// widget simply never heard from that session again.
public enum ShellWord {
    /// The value as a single shell word.
    ///
    /// Single quotes, because inside them a shell reads every character literally — a space,
    /// a `$`, a backslash. The one character they cannot hold is a single quote itself, so it
    /// is closed, escaped and reopened: a home directory really can be called `O'Brien`.
    public static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// The value a shell would read, given one word.
    ///
    /// A word with no quotes is returned as it stands, which is what keeps entries written by
    /// an earlier version recognisable.
    public static func unquoted(_ word: String) -> String {
        guard word.count >= 2, word.hasPrefix("'"), word.hasSuffix("'") else {
            return word
        }
        return word.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
    }
}
