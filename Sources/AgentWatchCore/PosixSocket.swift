import Darwin
import Dispatch
import Foundation

/// The three pieces of socket plumbing the sender, the listener and the hook executable all
/// needed, written once.
///
/// They were three copies of the same twenty lines in three targets: building a `sockaddr_un`
/// from a path, turning a millisecond timeout into a deadline, and waiting on a descriptor
/// without overrunning it. Nothing here decides anything — each caller still owns its own
/// error type and what a timeout means to it.
public enum PosixSocket {
    /// A moment on the monotonic clock, so a change to the wall clock cannot move a deadline.
    public static func deadline(afterMilliseconds milliseconds: Int32) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
    }

    /// Waits for any of `events` on the descriptor and answers with what actually happened,
    /// or `nil` if the deadline passed first or `poll` itself failed.
    ///
    /// The caller checks the flags: which of them count is the caller's question. A reader
    /// treats a hang-up as the end of the input; a writer does not.
    public static func waitForEvents(_ events: Int16, on descriptor: Int32, until deadline: UInt64) -> Int16? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            return nil
        }

        var descriptorToPoll = pollfd(fd: descriptor, events: events, revents: 0)
        // Rounded up, so a sub-millisecond remainder waits a moment rather than not at all.
        let remainingMilliseconds = Int32((deadline - now + 999_999) / 1_000_000)
        guard poll(&descriptorToPoll, 1, remainingMilliseconds) > 0 else {
            return nil
        }
        return descriptorToPoll.revents
    }

    /// A Unix domain address for this path, or `nil` when the path cannot hold one.
    ///
    /// `sun_path` is a fixed buffer of about a hundred bytes, and it has to end in a zero, so
    /// the length is checked before the copy rather than truncated into a path that points
    /// somewhere else.
    public static func makeAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.isEmpty, !pathBytes.contains(0), pathBytes.count < capacity else {
            return nil
        }

        address.sun_family = sa_family_t(AF_UNIX)
        let pathWithTerminator = pathBytes + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathWithTerminator.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }

    /// Hands the address to `connect` or `bind` in the shape C expects.
    public static func withSockaddr<T>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) rethrows -> T {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// The `--key value` command line both hook executables take.
///
/// Deliberately strict: an odd number of arguments, or a value where a `--key` was expected,
/// is a mistake in a hook configuration, and a hook that half-understands its arguments is
/// worse than one that does nothing.
public enum CommandLineOptions {
    public static func parse(_ arguments: [String]) -> [String: String]? {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let key = arguments[index]
            let valueIndex = index + 1
            guard key.hasPrefix("--"), valueIndex < arguments.count else {
                return nil
            }
            values[key] = arguments[valueIndex]
            index += 2
        }
        return values
    }
}
