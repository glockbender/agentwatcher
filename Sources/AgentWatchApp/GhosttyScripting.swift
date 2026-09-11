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
