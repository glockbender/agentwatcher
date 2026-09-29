import Darwin
import Foundation

/// Ending an agent whose terminal was closed while it stayed behind.
///
/// Measured on Claude Code 2.1.280 after a PyCharm tab was closed: the IDE still held both
/// ends of the terminal open, nothing drained it, and the agent's shutdown sat in
/// `tcsetattr` waiting for its last output to be taken. Neither `SIGTERM` nor `SIGKILL`
/// ended it — after `SIGKILL` it stays in exit (`E` in `ps`) until the terminal drains.
/// Discarding the unread output ends the wait, and the agent exits on its own a moment
/// later. `docs/agent-integration.md` has the reproduction; ADR-0013 the decision to do it
/// on a click.
///
/// A terminal Ghostty kept after closing its tab is the other way in, and needs the other
/// ending: that terminal is still drained, the agent is not exiting at all, and the hang-up
/// a closed tab sends is the one thing it never got.
enum ClosedTerminal {
    /// What a person runs to do the click's work by hand.
    ///
    /// `perl` because it is on every Mac and its `POSIX` module has `tcflush`; `stty` has no
    /// flush, and its `flusho` was tried and does not free the agent.
    static func releaseCommand(devicePath: String) -> String {
        #"perl -MPOSIX -e 'open(my $t, ">", $ARGV[0]) or die $!; tcflush(fileno($t), TCOFLUSH) or die $!' "#
            + devicePath
    }

    /// Only a pseudo-terminal's device, spelled the one way the kernel spells it.
    ///
    /// The path is read from another process's descriptors and then opened for writing, so
    /// nothing else may pass: not a disk, not a file, not a path that climbs out of `/dev`.
    static func isTerminalDevicePath(_ path: String) -> Bool {
        let prefix = "/dev/ttys"
        guard path.hasPrefix(prefix) else {
            return false
        }
        let number = path.dropFirst(prefix.count)
        return !number.isEmpty && number.allSatisfy(\.isASCIIDigit)
    }

    /// Throws away the output waiting in this terminal, and answers whether it could.
    ///
    /// Without blocking and without adopting the terminal: the app is nobody's session
    /// leader, and a terminal it opened must not become its own.
    static func discardUnreadOutput(devicePath: String) -> Bool {
        guard isTerminalDevicePath(devicePath) else {
            return false
        }
        let descriptor = open(devicePath, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        return tcflush(descriptor, TCOFLUSH) == 0
    }

    /// What a person runs to hang up an agent whose tab Ghostty closed and kept.
    static func hangUpCommand(processID: Int32) -> String {
        "kill -HUP \(processID)"
    }

    /// Sends the agent the hang-up its closed tab never did, and answers whether it went out.
    ///
    /// `SIGHUP` rather than `SIGTERM` because it is what closing a terminal sends. Claude
    /// Code 2.1.284 answers it with its ordinary shutdown — read in its code
    /// (`docs/measurements.md`).
    static func hangUp(processID: Int32) -> Bool {
        processID > 1 && kill(processID, SIGHUP) == 0
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
