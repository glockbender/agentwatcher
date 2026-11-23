import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

final class CodexProfileUsageTests: XCTestCase {
    private let id = "12f5d82b-d8fb-48f9-9326-44b856929fbe"

    private func line(
        percent: Int, at time: String, bucket: String = "codex", minutes: Int = 300,
        tokens: Int = 25, reset: Double = 2_000_000_000
    ) throws -> Data {
        let limits: [String: Any] = [
            "limit_id": bucket, "secondary": ["window_minutes": minutes, "used_percent": percent, "resets_at": reset],
        ]
        let payload: [String: Any] = [
            "type": "token_count", "rate_limits": limits,
            "info": ["total_token_usage": ["total_tokens": tokens]],
        ]
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "timestamp": time, "payload": payload,
        ])
        data.append(10)
        return data
    }

    func testNewestDatedStandardWindowIsUsedEvenWithOutOfOrderAndPartialRecords() throws {
        var data = Data("incomplete head\n".utf8)
        data += try line(percent: 35, at: "2026-11-01T12:00:02.125Z")
        data += try line(percent: 15, at: "2026-11-01T12:00:01Z")
        data += try line(percent: 90, at: "2026-11-01T12:00:03Z", bucket: "other-model")
        data += try line(percent: 50, at: "2026-11-01T12:00:04Z", minutes: 60)
        data += try line(percent: 201, at: "2026-11-01T12:00:05Z")
        data += try line(percent: 90, at: "yesterday")
        let reading = try XCTUnwrap(CodexProfileUsage.latest(inTail: data, sessionLabel: "chat"))
        XCTAssertEqual(
            reading.limits.fiveHour, .init(usedPercentage: 35, resetsAt: Date(timeIntervalSince1970: 2_000_000_000)))
        XCTAssertNil(reading.limits.sevenDay)
        XCTAssertEqual(reading.chatTokens, 25)
    }

    func testSamplesBelongToTheFolderThatHoldsTheObservedChat() throws {
        let scratch =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let home = scratch.appendingPathComponent(UUID().uuidString)
        let folders = ["personal", "work"].map { home.appendingPathComponent($0) }
        let label = HookCaptureRedactor.label(forRawIdentifier: id)
        for (i, folder) in folders.enumerated() {
            let root = TranscriptLocator.root(for: .codex, inFolder: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try line(percent: 30 + i, at: "2026-11-01T12:00:01Z", minutes: 10_080, tokens: -5, reset: -1)
            try data.write(to: root.appendingPathComponent("rollout-" + id + ".jsonl"))
        }
        for (i, folder) in folders.enumerated() {
            let reading = try XCTUnwrap(
                CodexProfileUsage.latest(in: folder, sessionLabels: [label], transcriptFiles: .live))
            XCTAssertEqual(reading.limits.sevenDay, .init(usedPercentage: Double(30 + i)))
            XCTAssertNil(reading.chatTokens)
            XCTAssertNil(CodexProfileUsage.latest(in: folder, sessionLabels: [label], transcriptFiles: nil))
            XCTAssertNil(CodexProfileUsage.latest(in: folder, sessionLabels: ["unobserved"], transcriptFiles: .live))
        }
    }
}
