import AgentWatchCore
import XCTest

final class ClaudeUsageSnapshotTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_795_210_525.765)
    private let account = "11111111-2222-3333-4444-555555555555"

    // MARK: - The snapshot in .claude.json

    func testReadsBothWindowsWithTheirResetTimesAsOfTheFetch() throws {
        let limits = try XCTUnwrap(
            ClaudeUsageSnapshot.limits(inConfigFile: configFile(), now: fetchedAt.addingTimeInterval(120)))

        XCTAssertEqual(limits.source, .claude)
        XCTAssertEqual(limits.observedAt, fetchedAt)
        XCTAssertEqual(limits.fiveHour?.usedPercentage, 18)
        XCTAssertEqual(limits.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_795_213_799))
        XCTAssertEqual(limits.sevenDay?.usedPercentage, 3)
        XCTAssertEqual(limits.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_795_806_000))
    }

    func testASnapshotPastAnHourIsNotTrusted() {
        let now = fetchedAt.addingTimeInterval(ClaudeUsageSnapshot.maximumAge + 1)
        XCTAssertNil(ClaudeUsageSnapshot.limits(inConfigFile: configFile(), now: now))
    }

    /// A clock that ran backwards is no reason to call an old figure new.
    func testASnapshotFromTheFutureIsNotTrusted() {
        XCTAssertNil(ClaudeUsageSnapshot.limits(inConfigFile: configFile(), now: fetchedAt.addingTimeInterval(-60)))
    }

    /// Claude Code drops a snapshot of another account on its own next read; until then the
    /// file still holds it.
    func testASnapshotOfAnotherAccountIsNotRead() {
        let data = configFile(signedIn: "99999999-2222-3333-4444-555555555555")
        XCTAssertNil(ClaudeUsageSnapshot.limits(inConfigFile: data, now: fetchedAt))
    }

    func testAFileCaughtMidWriteIsNotRead() {
        let data = configFile()
        XCTAssertNil(ClaudeUsageSnapshot.limits(inConfigFile: data.prefix(data.count / 2), now: fetchedAt))
    }

    func testAFileWithoutASnapshotIsNotRead() {
        XCTAssertNil(ClaudeUsageSnapshot.limits(inConfigFile: Data(#"{"numStartups":3}"#.utf8), now: fetchedAt))
    }

    func testAWindowSpentPastItsLimitReadsAsFull() throws {
        let data = configFile(fiveHour: #"{"utilization":104,"resets_at":null}"#)
        let limits = try XCTUnwrap(ClaudeUsageSnapshot.limits(inConfigFile: data, now: fetchedAt))
        XCTAssertEqual(limits.fiveHour, UsageWindow(usedPercentage: 100))
    }

    func testAWindowTheServerLeftEmptyIsLeftOut() throws {
        let data = configFile(fiveHour: "null")
        let limits = try XCTUnwrap(ClaudeUsageSnapshot.limits(inConfigFile: data, now: fetchedAt))
        XCTAssertNil(limits.fiveHour)
        XCTAssertNotNil(limits.sevenDay)
    }

    // MARK: - The get_usage reply

    func testTheRequestIsOneLineAskingOnlyForTheLimits() throws {
        let data = ClaudeUsageSnapshot.request(id: "r-1")
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "control_request")
        XCTAssertEqual(message["request_id"] as? String, "r-1")
        let request = try XCTUnwrap(message["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "get_usage")
        // Without it Claude Code scans every transcript of the last seven days.
        XCTAssertEqual(request["skip_behaviors"] as? Bool, true)
    }

    func testAReplyWithLimitsIsReadAsOfItsArrival() {
        let arrived = fetchedAt.addingTimeInterval(5)
        let line = reply(
            body:
                #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":21,"resets_at":"2026-11-20T22:29:59.750056+00:00"},"seven_day":null}}"#
        )

        XCTAssertEqual(
            ClaudeUsageSnapshot.reply(in: line, requestID: "r-1", now: arrived),
            .limits(
                AgentUsageLimits(
                    source: .claude,
                    fiveHour: UsageWindow(usedPercentage: 21, resetsAt: Date(timeIntervalSince1970: 1_795_213_799)),
                    observedAt: arrived)))
    }

    func testASignInWithoutPlanLimitsIsSaidSo() {
        let line = reply(body: #"{"rate_limits_available":false,"rate_limits":null}"#)
        XCTAssertEqual(ClaudeUsageSnapshot.reply(in: line, requestID: "r-1", now: fetchedAt), .noPlanLimits)
    }

    func testARefusalIsSaidSo() {
        let line = Data(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"r-1","error":"Unsupported control request subtype: get_usage"}}"#
                .utf8)
        XCTAssertEqual(ClaudeUsageSnapshot.reply(in: line, requestID: "r-1", now: fetchedAt), .refused)
    }

    func testAReplyToAnotherRequestIsNotThisOne() {
        let line = reply(body: #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":21}}}"#)
        XCTAssertEqual(ClaudeUsageSnapshot.reply(in: line, requestID: "r-2", now: fetchedAt), .unrecognised)
    }

    func testOtherOutputIsNotAReply() {
        let line = Data(#"{"type":"system","subtype":"init"}"#.utf8)
        XCTAssertEqual(ClaudeUsageSnapshot.reply(in: line, requestID: "r-1", now: fetchedAt), .unrecognised)
    }

    // MARK: - When to ask

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAsksWhenClaudeWorksAndNothingRecentIsKnown() {
        XCTAssertTrue(
            ClaudeUsageProbePolicy().shouldProbe(now: start, knownLimitsObservedAt: nil, claudeIsWorking: true))
    }

    func testNeverAsksWhileNoClaudeSessionWorks() {
        XCTAssertFalse(
            ClaudeUsageProbePolicy().shouldProbe(now: start, knownLimitsObservedAt: nil, claudeIsWorking: false))
    }

    func testDoesNotAskWhileWhatIsKnownIsRecent() {
        let known = start.addingTimeInterval(-ClaudeUsageProbePolicy.interval + 1)
        XCTAssertFalse(
            ClaudeUsageProbePolicy().shouldProbe(now: start, knownLimitsObservedAt: known, claudeIsWorking: true))
    }

    /// A run that failed is an attempt too: the next tick, fifteen seconds later, must not
    /// start another.
    func testAnAttemptHoldsTheNextOneForTheWholeInterval() {
        var policy = ClaudeUsageProbePolicy()
        policy.recordAttempt(at: start)

        let justBefore = start.addingTimeInterval(ClaudeUsageProbePolicy.interval - 1)
        XCTAssertFalse(policy.shouldProbe(now: justBefore, knownLimitsObservedAt: nil, claudeIsWorking: true))
        let after = start.addingTimeInterval(ClaudeUsageProbePolicy.interval)
        XCTAssertTrue(policy.shouldProbe(now: after, knownLimitsObservedAt: nil, claudeIsWorking: true))
    }

    func testAStoppedPolicyNeverAsksAgain() {
        var policy = ClaudeUsageProbePolicy()
        policy.stop()
        let muchLater = start.addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(policy.shouldProbe(now: muchLater, knownLimitsObservedAt: nil, claudeIsWorking: true))
    }

    // MARK: - Fixtures

    private func configFile(
        signedIn: String? = nil,
        fiveHour: String = #"{"utilization":18,"resets_at":"2026-11-20T22:29:59.750056+00:00","limit_dollars":null}"#
    ) -> Data {
        Data(
            """
            {
              "numStartups": 412,
              "oauthAccount": {"accountUuid": "\(signedIn ?? account)"},
              "cachedUsageUtilization": {
                "fetchedAtMs": 1795210525765,
                "accountUuid": "\(account)",
                "utilization": {
                  "five_hour": \(fiveHour),
                  "seven_day": {"utilization": 3, "resets_at": "2026-11-27T19:00:00+00:00"},
                  "seven_day_opus": null,
                  "amber_gauge": null
                }
              }
            }
            """.utf8)
    }

    private func reply(body: String) -> Data {
        Data(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"r-1","response":\#(body)}}"#.utf8
        )
    }
}
