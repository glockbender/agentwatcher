import Darwin
import Foundation
import XCTest

@testable import AgentWatchGit

final class GitCommandTests: XCTestCase {
    func testReadsOutputWithoutLosingEmbeddedNewlines() throws {
        let folder = try scratch()
        let result = try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["one\ntwo"], in: folder, timeout: 1)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "one\ntwo\n")
    }

    func testTimeoutKillsAndReapsAProcessThatIgnoresTermination() throws {
        let folder = try scratch()
        let pidFile = folder.appendingPathComponent("pid")
        let started = Date()
        XCTAssertThrowsError(try Self.sleeper(in: folder, pidFile: pidFile, timeout: 0.2)) { error in
            XCTAssertEqual(error as? BoundedCommand.Failure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationStopsTheChildWhileItsOutputPipeIsIdle() async throws {
        let folder = try scratch()
        let pidFile = folder.appendingPathComponent("pid")
        let operation = Task.detached { @Sendable [folder, pidFile] in
            try GitCommandTests.sleeper(in: folder, pidFile: pidFile, timeout: 30)
        }
        defer { operation.cancel() }
        var pid: Int32?
        for _ in 0..<100 {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init)
            if pid != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try XCTUnwrap(pid)
        let cancelled = Date()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("A cancelled process must not report success")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 3)
        }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testExcessiveOutputIsBounded() throws {
        XCTAssertThrowsError(
            try BoundedCommand.run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], in: try scratch(),
                timeout: 1, outputLimit: 1024)
        ) { error in
            XCTAssertEqual(error as? BoundedCommand.Failure, .outputLimit)
        }
    }

    func testDrainsDelayedFinalOutputAndWaitsForExitAfterEarlyEOF() throws {
        let folder = try scratch()
        let finalOutput = try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 0.02; printf final"], in: folder, timeout: 1)
        XCTAssertEqual(String(decoding: finalOutput.output, as: UTF8.self), "final")
        XCTAssertEqual(finalOutput.status, 0)

        let closedOutput = try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; /bin/sleep 0.02; exit 7"], in: folder, timeout: 1)
        XCTAssertEqual(closedOutput.status, 7)
        XCTAssertTrue(closedOutput.output.isEmpty)
    }

    private static func sleeper(in folder: URL, pidFile: URL, timeout: TimeInterval) throws -> GitCommand.Result {
        try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf '%s' $$ > \"$1\"; exec /bin/sleep 30", "fixture", pidFile.path],
            in: folder, timeout: timeout)
    }

    private func scratch() throws -> URL {
        let root =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let folder = root.appendingPathComponent("GitCommand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
