import AgentWatchCore
import Darwin
import Foundation
import XCTest

@testable import AgentWatchSender

final class DebugHookPayloadRecorderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testWritesTheOriginalPayloadWithACorrelationLabel() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let input = Data(#"{"session_id":"session-secret","prompt":"private instruction"}"#.utf8)
        XCTAssertTrue(try record(input, index: 0, directoryURL: directoryURL))

        let line = try XCTUnwrap(lines(in: directoryURL).first)
        XCTAssertTrue(line.contains("private instruction"))
        XCTAssertTrue(line.contains("session-secret"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "codex")
        XCTAssertEqual(object["declared_event"] as? String, "SessionStart")
        XCTAssertTrue((object["session_id_label"] as? String)?.hasPrefix("id_") == true)
    }

    /// The switch bounds how long recording runs. It never bounded how long the recording
    /// lives, and nothing else did either — a capture that stopped at breakfast still held
    /// that morning's paths and shell commands at midnight, with no way to remove it from
    /// the app. So the recorded bytes are countable, and deletable, on their own.
    func testRecordedPayloadsCanBeCountedAndDeletedAfterRecordingHasStopped() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))
        XCTAssertTrue(
            try record(
                Data(#"{"session_id":"s","cwd":"/Users/someone/work"}"#.utf8), index: 0,
                directoryURL: directoryURL))

        XCTAssertGreaterThan(DebugHookCaptureControl.recordedByteCount(directoryURL: directoryURL), 0)

        // Stopping is not deleting: a person stops recording in order to read what they
        // recorded, so the two are separate actions and the count survives the first.
        DebugHookCaptureControl.disable(directoryURL: directoryURL)
        XCTAssertGreaterThan(DebugHookCaptureControl.recordedByteCount(directoryURL: directoryURL), 0)

        DebugHookCaptureControl.deleteRecordings(directoryURL: directoryURL)
        XCTAssertEqual(DebugHookCaptureControl.recordedByteCount(directoryURL: directoryURL), 0)
        XCTAssertTrue(lines(in: directoryURL).isEmpty)
    }

    func testExpiresWithoutCreatingACaptureFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 10, directoryURL: directoryURL))

        let input = Data(#"{"session_id":"session"}"#.utf8)
        XCTAssertFalse(try record(input, index: 0, now: start.addingTimeInterval(10), directoryURL: directoryURL))
        XCTAssertTrue(lines(in: directoryURL).isEmpty)
    }

    func testRefusesToFollowASegmentSymlink() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let targetURL = directoryURL.appendingPathComponent("target.jsonl")
        let currentURL = directoryURL.appendingPathComponent("hook-events.current.jsonl")
        try FileManager.default.createSymbolicLink(at: currentURL, withDestinationURL: targetURL)

        let input = Data(#"{"session_id":"session"}"#.utf8)
        XCTAssertFalse(try record(input, index: 0, directoryURL: directoryURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
    }

    func testCreatesOwnerOnlyDirectoryStateLockAndSegmentFiles() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let input = Data(#"{"session_id":"session"}"#.utf8)
        XCTAssertTrue(try record(input, index: 0, directoryURL: directoryURL))

        XCTAssertEqual(permissions(of: directoryURL), 0o700)
        XCTAssertEqual(permissions(of: directoryURL.appendingPathComponent("capture-state.json")), 0o600)
        XCTAssertEqual(permissions(of: directoryURL.appendingPathComponent(".hook-events.lock")), 0o600)
        XCTAssertEqual(permissions(of: directoryURL.appendingPathComponent("hook-events.current.jsonl")), 0o600)
    }

    func testFailedPartialWriteRestoresTheLastCompleteJSONLBoundary() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let input = Data(#"{"session_id":"session"}"#.utf8)
        XCTAssertTrue(try record(input, index: 0, directoryURL: directoryURL))
        let currentURL = directoryURL.appendingPathComponent("hook-events.current.jsonl")
        let before = try Data(contentsOf: currentURL)

        XCTAssertThrowsError(
            try DebugHookPayloadRecorder.append(Data("{\"partial\":true}\n".utf8), in: directoryURL) {
                data,
                descriptor in
                let partialLength = min(5, data.count)
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress, partialLength)
                }
                XCTAssertEqual(written, partialLength)
                throw PartialWriteFailure.failed
            })
        XCTAssertEqual(try Data(contentsOf: currentURL), before)
    }

    func testRollsSegmentsWithoutEverExceedingTheTenMiBCap() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        for index in 0..<16 {
            let input = payload(index: index, fillerCount: 900_000)
            XCTAssertTrue(try record(input, index: index, directoryURL: directoryURL))
        }

        let files = try jsonlFiles(in: directoryURL)
        XCTAssertLessThanOrEqual(files.count, 5)
        let total = try files.reduce(0) { partial, url in
            partial + Int(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, DebugHookPayloadRecorder.maximumTotalByteCount)

        let captureLines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        XCTAssertTrue(
            captureLines.allSatisfy { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
            })
        XCTAssertFalse(captureLines.contains { $0.contains("session-0") })
        XCTAssertTrue(captureLines.contains { $0.contains("session-15") })
    }

    /// A hook whose payload ends in a newline is the ordinary case — the documented example
    /// does exactly that. Spliced in raw, the newline ended the record early and left the
    /// rest as a second line that parses as nothing, so a capture became unreadable by the
    /// only tool it exists for.
    func testAPayloadEndingInANewlineStaysOneLine() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let input = Data("{\"session_id\":\"session-secret\"}\n".utf8)
        XCTAssertTrue(try record(input, index: 0, directoryURL: directoryURL))

        let file = try XCTUnwrap(try jsonlFiles(in: directoryURL).first)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1, "one record is one line")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contents.dropLast().utf8)) as? [String: Any]
        )
        XCTAssertNotNil(object["payload"])
    }

    /// Pretty-printed input cannot be written on one line, and re-encoding it from the
    /// decoded value would cost the two things a raw capture is kept for: exact numbers and
    /// repeated keys. So it is dropped whole, like everything else this recorder cannot do.
    func testAPayloadWithANewlineInsideIsRefusedRatherThanMangled() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(now: start, duration: 60, directoryURL: directoryURL))

        let pretty = Data("{\n  \"session_id\": \"session\"\n}".utf8)

        XCTAssertFalse(try record(pretty, index: 0, directoryURL: directoryURL))
        XCTAssertTrue(lines(in: directoryURL).isEmpty)
    }

    /// The whole path, and the only test that takes it: a hook process, the recorder it
    /// starts, a file on disk. Everything else here calls the recorder directly, which is how
    /// a launcher that had never once started went unnoticed — the payload travels through
    /// shared memory whose name Darwin cuts off at 31 characters, and a longer one fails
    /// silently every time.
    func testTheHookProcessStartsTheRecorderAndAFileAppears() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        XCTAssertTrue(DebugHookCaptureControl.enable(duration: 60, directoryURL: directoryURL))

        try runSender(
            input: Data(#"{"hook_event_name":"SessionStart","session_id":"end-to-end"}"#.utf8),
            captureDirectory: directoryURL
        )

        // The recorder is a second process that outlives its parent by design, so the file
        // appears shortly after the hook has already returned.
        let deadline = Date().addingTimeInterval(5)
        while lines(in: directoryURL).isEmpty, Date() < deadline {
            usleep(50_000)
        }

        let recorded = lines(in: directoryURL)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded.first?.contains("end-to-end") == true)
    }

    private func runSender(input: Data, captureDirectory: URL) throws {
        let process = Process()
        process.executableURL = packageRootURL.appendingPathComponent(".build/debug/AgentWatchSend")
        process.arguments = [
            "--source", "claude",
            "--event", "SessionStart",
            // Nothing listens there. The event is dropped, which is the ordinary fail-open
            // path; what this test watches happens beside it.
            "--socket", captureDirectory.appendingPathComponent("no-such.sock").path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[DebugHookCaptureControl.directoryOverrideVariable] = captureDirectory.path
        process.environment = environment
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func record(
        _ input: Data,
        index: Int,
        now: Date? = nil,
        directoryURL: URL
    ) throws -> Bool {
        let payload = try JSONDecoder().decode(JSONValue.self, from: input)
        return DebugHookPayloadRecorder.record(
            source: .codex,
            declaredEvent: "SessionStart",
            rawPayload: input,
            decodedPayload: payload,
            now: now ?? start.addingTimeInterval(Double(index)),
            directoryURL: directoryURL
        )
    }

    private func payload(index: Int, fillerCount: Int) -> Data {
        Data(#"{"session_id":"session-\#(index)","prompt":"\#(String(repeating: "x", count: fillerCount))"}"#.utf8)
    }

    private func lines(in directoryURL: URL) -> [String] {
        (try? jsonlFiles(in: directoryURL).flatMap {
            try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init)
        })
            ?? []
    }

    private func jsonlFiles(in directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("agent-watch-debug-capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(of url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private enum PartialWriteFailure: Error {
        case failed
    }
}
