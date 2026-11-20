import Darwin
import Foundation

/// Runs Git without inheriting a parent hook's repository selection. Every call is bounded,
/// including one blocked on a pipe; cancellation is checked in the calling task.
public enum GitCommand {
    public struct Result: Sendable {
        public let status: Int32
        public let output: Data
    }

    public static func run(_ arguments: [String], in folder: URL, timeout: TimeInterval = 5) throws -> Result {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Project inspection must stay local, including when objects are missing in a partial clone.
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_ALLOW_PROTOCOL"] = ""
        return try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.fsmonitor=false"] + arguments, in: folder,
            environment: environment, timeout: timeout)
    }
}

package enum BoundedCommand {
    package static func run(
        executable: URL, arguments: [String], in folder: URL, environment: [String: String] = [:],
        timeout: TimeInterval, outputLimit: Int = 4 * 1024 * 1024
    ) throws -> GitCommand.Result {
        try Task.checkCancellation()
        guard timeout > 0, timeout.isFinite else { throw Failure.timedOut }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.cannotRead }
        defer { try? pipe.fileHandleForReading.close() }
        do { try process.run() } catch { throw Failure.cannotRun }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        do {
            while true {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw Failure.timedOut }
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    guard count <= outputLimit - output.count else { throw Failure.outputLimit }
                    output.append(contentsOf: buffer.prefix(count))
                } else {
                    guard count == 0 || errno == EAGAIN || errno == EINTR else { throw Failure.cannotRead }
                    if count == 0 {
                        if !process.isRunning { break }
                        // A program may close stdout before finishing. Polling an EOF
                        // descriptor would wake immediately and spin until it exits.
                        Thread.sleep(forTimeInterval: 0.02)
                    } else {
                        // EAGAIN is not EOF: the process may write its final bytes and
                        // exit before isRunning is observed. Keep draining to real EOF.
                        var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                        _ = poll(&event, 1, 20)
                    }
                }
            }
            process.waitUntilExit()
            return GitCommand.Result(status: process.terminationStatus, output: output)
        } catch {
            stop(process)
            throw error
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(100))
        while process.isRunning && clock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    enum Failure: LocalizedError, Equatable {
        case cannotRun, cannotRead, timedOut, outputLimit

        var errorDescription: String? {
            switch self {
            case .cannotRun: "Could not start Git in the selected folder."
            case .cannotRead: "Could not read Git’s result."
            case .timedOut: "Git took too long. Its process was stopped; try again when the disk is less busy."
            case .outputLimit: "Git returned more data than this check can safely read."
            }
        }
    }
}
