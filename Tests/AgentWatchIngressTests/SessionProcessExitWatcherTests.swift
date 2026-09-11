import AgentWatchIngress
import Foundation
import XCTest

final class SessionProcessExitWatcherTests: XCTestCase {
    func testCallsBackWithTheSessionWhoseProcessExited() throws {
        let exited = expectation(description: "process exit")
        let watcher = SessionProcessExitWatcher { sessionID in
            XCTAssertEqual(sessionID, "claude:session")
            exited.fulfill()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        watcher.watch(sessionID: "claude:session", processID: process.processIdentifier)
        process.terminate()

        wait(for: [exited], timeout: 1)
    }

    func testIgnoringAnExitFromAReplacedProcessKeepsTheNewWatchActive() throws {
        let exited = expectation(description: "new process exit")
        let unexpectedExit = expectation(description: "replaced process exit")
        unexpectedExit.isInverted = true
        let expectationState = ExitExpectationState()
        let oldProcess = try startSleepProcess()
        let newProcess = try startSleepProcess()
        let watcher = SessionProcessExitWatcher { _ in
            if expectationState.isExpectingNewProcessExit {
                exited.fulfill()
            } else {
                unexpectedExit.fulfill()
            }
        }
        defer {
            if oldProcess.isRunning {
                oldProcess.terminate()
            }
            if newProcess.isRunning {
                newProcess.terminate()
            }
        }

        watcher.watch(sessionID: "claude:session", processID: oldProcess.processIdentifier)
        watcher.watch(sessionID: "claude:session", processID: newProcess.processIdentifier)
        oldProcess.terminate()
        wait(for: [unexpectedExit], timeout: 0.2)

        expectationState.expectNewProcessExit()
        newProcess.terminate()
        wait(for: [exited], timeout: 1)
    }

    func testUnwatchingAProcessPreventsItsExitCallback() throws {
        let unexpectedExit = expectation(description: "unwatched process exit")
        unexpectedExit.isInverted = true
        let watcher = SessionProcessExitWatcher { _ in
            unexpectedExit.fulfill()
        }
        let process = try startSleepProcess()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        watcher.watch(sessionID: "claude:session", processID: process.processIdentifier)
        watcher.unwatch(sessionID: "claude:session")
        process.terminate()

        wait(for: [unexpectedExit], timeout: 0.2)
    }

    private func startSleepProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }
}

private final class ExitExpectationState: @unchecked Sendable {
    private let lock = NSLock()
    private var expectingNewProcessExit = false

    var isExpectingNewProcessExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expectingNewProcessExit
    }

    func expectNewProcessExit() {
        lock.lock()
        expectingNewProcessExit = true
        lock.unlock()
    }
}
