import Foundation

/// Reaching a background session: the one row with no window of its own.
///
/// Claude Code runs such a session inside `claude bg-spare`, under `claude bg-pty-host`, with
/// `launchd` above that — so there is no terminal tab anywhere to bring forward, and the
/// process tree will never grow one. What there is instead is a door: `claude attach <job id>`
/// shows the session in whatever terminal it is typed into, and `Ctrl+Z` there drops back to
/// the shell with the session still running. So a click on the row opens a fresh terminal
/// tab and types that line, and the rules for what gets typed live here, where they can be
/// checked without a terminal, a disk or Ghostty.
///
/// The job identifier is not something the hooks carry: a session's own identifier reaches
/// this app redacted (`docs/architecture.md` §15), and the job id is a separate, shorter name
/// anyway — the one `claude agents` lists and `claude attach` takes. Claude Code writes it into
/// its own record of the process, `~/.claude/sessions/<pid>.json`, beside the session's kind and
/// name; that file is measured, not documented, so a record without the field is answered with
/// nothing rather than with a guess. `docs/agent-integration.md` §1б.
public enum BackgroundSessionAttach {
    /// Claude Code's own record of a running process, named after its process number.
    public static func sessionRecordURL(claudeHome: URL, agentProcessID: Int32) -> URL {
        claudeHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(agentProcessID).json", isDirectory: false)
    }

    /// The job identifier in one such record, or `nil` when there is none worth typing.
    ///
    /// An interactive session has a record too and no `jobId` in it, which is the ordinary
    /// answer and not a fault. A value that is not a plain identifier is refused for the same
    /// reason `GhosttyFocus.isAddressableTerminalID` refuses one: it is about to be typed into
    /// a shell, and only a shape that cannot carry a command may go there.
    public static func jobID(inSessionRecord data: Data) -> String? {
        guard
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let jobID = document["jobId"] as? String,
            isAddressableJobID(jobID)
        else {
            return nil
        }
        return jobID
    }

    /// The terminal process that shows this job, or `nil` when no live one does.
    ///
    /// `/bg` does not free the terminal it was typed in: the interactive process stays, its own
    /// record names the job in `parkedJobId`, and the session is on screen right there — so
    /// that terminal is the session's window, and a click on the row belongs to it, not to a
    /// fresh tab with `claude attach`. Measured on 2.1.269, and undocumented like the rest of
    /// the record: the docs speak of the terminal as freed, and of `parkedJobId` not at all.
    ///
    /// Only an interactive record counts. The job's own record names the job as `jobId` and
    /// is no viewer of itself. And only a live process: the file outlives its process, so a
    /// record alone says "showed it once", never "shows it now". The number is read as
    /// Claude Code writes it, a number, and in the quoted spelling older records used.
    /// - Parameter isProcessAlive: whether the process with this number is running, and is
    ///   the one the record is about — the record's own start time is passed along so a
    ///   number handed out again can be told from the original. `nil` when the record has
    ///   none.
    public static func viewerProcessID(
        ofJob jobID: String,
        inSessionRecords records: [Data],
        isProcessAlive: (Int32, Date?) -> Bool
    ) -> Int32? {
        for data in records {
            guard
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                record["kind"] as? String == "interactive",
                record["parkedJobId"] as? String == jobID,
                let processID = processID(in: record),
                isProcessAlive(processID, startedAt(in: record))
            else {
                continue
            }
            return processID
        }
        return nil
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

    private static func processID(in record: [String: Any]) -> Int32? {
        if let number = record["pid"] as? Int, let processID = Int32(exactly: number) {
            return processID
        }
        if let text = record["pid"] as? String {
            return Int32(text)
        }
        return nil
    }

    /// Letters, digits, `_` and `-`, and nothing else — a shell reads none of those specially.
    /// Not starting with `-`, because `claude` would read that as an option rather than a job.
    public static func isAddressableJobID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, !id.hasPrefix("-") else {
            return false
        }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isASCIIHexDigit
                || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || scalar == "_" || scalar == "-"
        }
    }

    public enum Decision: Equatable, Sendable {
        /// A viewer of this job is on screen already: bring its terminal forward.
        case focus(terminalID: String)
        /// Open a new tab and type this line into it.
        case openTab(typing: String)
        /// The identifier may not be typed anywhere.
        case decline
    }

    /// What one press does for a background session, given what Ghostty and the process list
    /// say.
    ///
    /// Pressing twice must not open the session twice. While a viewer runs, Ghostty titles its
    /// tab after the command it runs — measured as `claude attach 3345bfdf` — so a tab named
    /// exactly that, while such a process exists, is the session on screen already. Two such
    /// tabs are both right, unlike two tabs sharing a session's *name* (`GhosttyFocus` refuses
    /// those): the title carries the job id, so the one Ghostty lists first is taken rather
    /// than a third one opened — its list is in the order the tabs were opened, where a
    /// terminal's identifier is a UUID and orders nothing. A title with no process behind it
    /// is not trusted: a title outlives the program that set it, and a tab whose shell had sat
    /// idle for a day still carried a session's name. The promise reaches as far as Ghostty's
    /// tabs: a viewer somebody started in another terminal application is not seen from here,
    /// and a press opens a Ghostty one beside it.
    public static func decision(
        among terminals: [GhosttyTerminal],
        jobID: String,
        viewerIsRunning: Bool
    ) -> Decision {
        guard let line = command(attaching: jobID) else {
            return .decline
        }
        if viewerIsRunning,
            let viewer = terminals.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == line })
        {
            return .focus(terminalID: viewer.id)
        }
        return .openTab(typing: line)
    }

    /// The line typed into the new terminal, or `nil` for an identifier that may not be typed.
    ///
    /// `claude` by name rather than by path: the terminal runs the person's own shell, and
    /// their shell knows where their `claude` is — the agent's executable would only say which
    /// build the *session* runs, and attaching is a job for the current one.
    public static func command(attaching jobID: String) -> String? {
        guard isAddressableJobID(jobID) else {
            return nil
        }
        return "claude attach \(jobID)"
    }
}
