import Darwin

/// Ending a headless run on a person's word (ADR-0021).
///
/// `SIGTERM`, the ordinary request to stop. Claude Code answered it with exit 143 and its
/// `SessionEnd` in under a second, measured on Claude Code 2.1.293; `SIGINT` did the same with
/// exit 0. What `codex exec` does with either is not measured. The row does not wait on that:
/// the run's process is watched, and its exit closes the row.
enum HeadlessRun {
    /// What a person runs to do the click's work by hand.
    static func terminateCommand(processID: Int32) -> String {
        "kill \(processID)"
    }

    static func terminate(processID: Int32) -> Bool {
        guard mayTerminate(processID, ownProcessID: getpid()) else {
            return false
        }
        return kill(processID, SIGTERM) == 0
    }

    /// Never zero, one or a negative number, which `kill` reads as a whole group of processes
    /// or all of them, and never this app.
    static func mayTerminate(_ processID: Int32, ownProcessID: Int32) -> Bool {
        processID > 1 && processID != ownProcessID
    }
}
