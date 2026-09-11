import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The relay is a shell script, so these tests run it. Nothing else can show the property it
/// exists for: that a person's status line keeps working when Agent Watch does not.
final class StatusLineRelayTests: XCTestCase {
    func testTheRelayPrintsWhatTheOriginalCommandPrintsAndHandsACopyOnward() throws {
        let directory = try makeDirectory()
        let received = directory.appendingPathComponent("received.json")
        let sender = try makeSender(in: directory, recordingTo: received)

        let output = try run(
            StatusLineRelay.script(senderPath: sender.path, originalCommand: "/bin/cat"),
            in: directory,
            payload: #"{"session_id":"abc"}"#
        )

        XCTAssertEqual(output.standardOutput, #"{"session_id":"abc"}"#)
        XCTAssertEqual(output.exitCode, 0)
        // Waited for rather than read straight away: the relay hands the payload over in the
        // background on purpose, so that a sender costing the best part of a second does not
        // delay what the person sees.
        XCTAssertEqual(try waitForContents(of: received), #"{"session_id":"abc"}"#)
    }

    /// The property the whole design turns on. Agent Watch stopped, uninstalled or broken
    /// must be invisible from where the person is looking.
    func testASenderThatIsNotThereChangesNothingThePersonSees() throws {
        let directory = try makeDirectory()

        let output = try run(
            StatusLineRelay.script(
                senderPath: directory.appendingPathComponent("no-such-sender").path,
                originalCommand: "/bin/cat"
            ),
            in: directory,
            payload: #"{"session_id":"abc"}"#
        )

        XCTAssertEqual(output.standardOutput, #"{"session_id":"abc"}"#)
        XCTAssertEqual(output.exitCode, 0)
    }

    /// A status line that fails is a fact Claude Code should see, so the person's own exit
    /// code passes through rather than being swallowed by a wrapper they did not ask for.
    func testTheOriginalCommandsExitCodeIsTheRelaysExitCode() throws {
        let directory = try makeDirectory()

        let output = try run(
            StatusLineRelay.script(senderPath: "/bin/true", originalCommand: "cat > /dev/null; exit 7"),
            in: directory,
            payload: "{}"
        )

        XCTAssertEqual(output.exitCode, 7)
    }

    /// The ordinary starting state, and the one the round trip did not cover: most people have
    /// no status line of their own. With nothing to wrap there must still be a script that
    /// runs — a pipe into an empty command is a syntax error, and a person whose status line
    /// was blank would find it broken instead.
    func testWithNoCommandToWrapTheRelayStillRunsAndShowsNothing() throws {
        let directory = try makeDirectory()
        let received = directory.appendingPathComponent("received.json")
        let sender = try makeSender(in: directory, recordingTo: received)

        let output = try run(
            StatusLineRelay.script(senderPath: sender.path, originalCommand: ""),
            in: directory,
            payload: #"{"session_id":"abc"}"#
        )

        XCTAssertEqual(output.standardOutput, "")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(try waitForContents(of: received), #"{"session_id":"abc"}"#)
    }

    private func waitForContents(of url: URL, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Non-empty, not merely present: a shell creates the file when the command
            // starts and fills it when the payload arrives, and the gap between the two is
            // exactly what this loop is waiting out.
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw XCTSkip("the relay never handed the payload on")
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchRelayTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stands in for the sender: records what reached it, so the test can tell "handed on"
    /// from "silently dropped".
    private func makeSender(in directory: URL, recordingTo target: URL) throws -> URL {
        let url = directory.appendingPathComponent("sender.sh")
        try Data("#!/bin/bash\ncat > '\(target.path)'\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func run(
        _ script: String,
        in directory: URL,
        payload: String
    ) throws -> (standardOutput: String, exitCode: Int32) {
        let url = directory.appendingPathComponent("relay.sh")
        try Data(script.utf8).write(to: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
