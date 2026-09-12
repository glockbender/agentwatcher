import AgentWatchCore
import Foundation

/// Talking to Ghostty over Apple events.
///
/// Two calls, never one. The obvious script — «focus the first terminal whose name ends with
/// …» — would put the session's name inside the script, and that name is an agent's output:
/// a quote in it breaks the script and anything worse writes one. So the names come back as
/// data, the choice is made in Swift, and the only thing ever written into a script is a
/// terminal identifier that has been checked to be a `UUID`.
///
/// Synchronous, on the caller's thread, and that is a choice about one moment: the first
/// press shows the system's «Agent Watch wants to control Ghostty» dialog, which is modal
/// anyway. Two Apple events to a local application take milliseconds after that.
enum GhosttyScripting {
    static let bundleIdentifier = "com.mitchellh.ghostty"

    /// Every terminal Ghostty has open, or nothing when it will not say.
    ///
    /// Asked as one event rather than two — `{id, name}` — so the two lists are a single
    /// snapshot. Asking twice would let a tab open or close in between and pair a name with
    /// somebody else's identifier.
    static func terminals() -> [GhosttyTerminal]? {
        guard
            let reply = run("tell application id \"\(bundleIdentifier)\" to get {id, name} of every terminal"),
            reply.numberOfItems == 2,
            let ids = reply.atIndex(1),
            let names = reply.atIndex(2),
            ids.numberOfItems == names.numberOfItems
        else {
            return nil
        }
        guard ids.numberOfItems > 0 else {
            return []
        }
        // Apple event lists are indexed from one.
        return (1...ids.numberOfItems).compactMap { index in
            guard
                let id = ids.atIndex(index)?.stringValue,
                let name = names.atIndex(index)?.stringValue
            else {
                return nil
            }
            return GhosttyTerminal(id: id, name: name)
        }
    }

    /// Brings one terminal's window and tab to the front. Ghostty's `focus` does both.
    static func focus(terminalID: String) -> Bool {
        guard GhosttyFocus.isAddressableTerminalID(terminalID) else {
            return false
        }
        return run("tell application id \"\(bundleIdentifier)\" to focus terminal id \"\(terminalID)\"") != nil
    }

    /// Opens a new tab and types one line into it, answering with the new terminal's
    /// identifier — or `nil` when no terminal appeared.
    ///
    /// The line goes in as the tab's *initial input* rather than as its command, and Ghostty
    /// itself does the same to open a script: the tab starts the person's own login shell, so
    /// their `PATH` and profile apply — `claude` is found wherever they keep it — and when the
    /// program exits the shell is still there. Ghostty writes the input to the pty as-is, so
    /// the line feed is a real one; measured with a `touch` typed this way.
    ///
    /// Judged by the terminal list rather than by the command's reply, and that too is
    /// measured: Ghostty 1.3.1 creates the tab and then fails to hand the tab object back, so
    /// `new tab` answers −1708 for a tab that is there. The ids before and after, and the new
    /// one read off the difference, are true either way. With no window to add a tab to —
    /// Ghostty was just launched by the script — a window is asked for instead.
    static func openTab(typing line: String) -> String? {
        guard isTypeable(line) else {
            return nil
        }
        let before = Set(terminals()?.map(\.id) ?? [])
        let configuration = "{initial input:\"\(line)\" & linefeed}"
        _ = run("tell application id \"\(bundleIdentifier)\" to new tab with configuration \(configuration)")
        var added = Set(terminals()?.map(\.id) ?? []).subtracting(before)
        if added.isEmpty {
            _ = run("tell application id \"\(bundleIdentifier)\" to new window with configuration \(configuration)")
            added = Set(terminals()?.map(\.id) ?? []).subtracting(before)
        }
        // One terminal appeared in the time it took: that is the tab just asked for. Two would
        // mean somebody else opened one in the same instant, and either is still ours to
        // focus rather than nothing.
        return added.sorted().first
    }

    /// Whether a line can be written into a script and then typed into a shell.
    ///
    /// Letters, digits, spaces, `_`, `-` and `.`, and nothing else: both places would read a
    /// quote, a `;` or a `$` as more than text. The one line typed today is `claude attach`
    /// and a job identifier already checked by `BackgroundSessionAttach`, so this is a second
    /// fence around the same field rather than the first.
    static func isTypeable(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 200 else {
            return false
        }
        return line.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == " " || scalar == "_" || scalar == "-" || scalar == "."
        }
    }

    /// One script, run and answered. An error — a refused permission most of all — is a
    /// `nil` here and a "window only" press for the person, never a thrown exception: this
    /// runs on a button they pressed, and monitoring that interrupts is worse than
    /// monitoring that quietly does less.
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            return nil
        }
        var failure: NSDictionary?
        let reply = script.executeAndReturnError(&failure)
        return failure == nil ? reply : nil
    }
}
