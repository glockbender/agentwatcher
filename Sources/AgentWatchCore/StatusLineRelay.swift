import Foundation

/// What Claude Code's one status-line slot currently holds.
public enum StatusLineState: Equatable, Sendable {
    /// Nothing is set. Connecting takes the slot and gives nothing up.
    case notSet
    /// Our relay is in front, and somebody's own command may be behind it.
    case connected
    /// Someone else's command holds the slot. Untouched until a person says otherwise, and
    /// then wrapped rather than replaced.
    case theirs(command: String)
    /// The settings file is there and this app cannot read it, so what holds the slot is not
    /// known. Reported rather than guessed at: taking the slot would mean writing a file
    /// whose other contents nobody can state.
    case unreadable
}

/// The script Agent Watch puts in front of a person's own status-line command.
///
/// Claude Code allows one status-line command, and it is usually already taken. The only
/// source of a context percentage for Claude is the payload that command receives — the
/// transcript carries token counts with nothing to say what they are a fraction of, and a
/// table of window sizes by model would go quietly out of date.
///
/// So the app writes a script of its own and never touches the person's. Their command is
/// copied into it verbatim and runs last, so what they see is whatever it prints.
public enum StatusLineRelay {
    /// What the sender is told the payload is.
    public static let event = "StatusLine"

    public static func script(senderPath: String, originalCommand: String) -> String {
        """
        #!/bin/bash
        # Written by Agent Watch. This does NOT replace your status line.
        #
        # Claude Code allows one status-line command, and Agent Watch needs the same payload
        # to show how full a session's context window is. So this script hands your payload
        # to Agent Watch and then runs your own command unchanged — what you see is whatever
        # your command prints.
        #
        # Your original command is the last line here, and a copy is in original-command.txt
        # beside this file. If Agent Watch is stopped, removed or broken, your status line
        # still works: the line that hands the payload over cannot fail this script.
        #
        # To undo: Agent Watch menu -> Tooling -> Status line. Or put your own command back
        # into "statusLine" in ~/.claude/settings.json by hand.

        payload="$(cat)"

        # Backgrounded, silenced, and its failure discarded. A missing binary, a stopped app
        # or a broken socket must not reach the line below.
        printf '%s' "$payload" | \(ShellWord.quoted(senderPath)) --source claude --event \(event) >/dev/null 2>&1 &

        \(tail(for: originalCommand))
        """
    }

    /// The last line, which is the person's command — or, when there is none, an honest
    /// nothing.
    ///
    /// Having no status line is the ordinary starting state, and it needs this case of its
    /// own: piping into an empty command is a shell syntax error, so a person whose status
    /// line was blank would find it broken rather than unchanged.
    private static func tail(for originalCommand: String) -> String {
        guard !originalCommand.isEmpty else {
            return """
                # There was no status-line command here before Agent Watch, so nothing is
                # printed and the status line stays as empty as it was. Put your own command
                # on a line below to have one; Agent Watch keeps working either way.
                exit 0
                """
        }
        return """
            # Your command, exactly as it was, with your payload and your exit code.
            printf '%s' "$payload" | /bin/bash -c \(ShellWord.quoted(originalCommand))
            """
    }
}
