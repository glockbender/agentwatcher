import AgentWatchCore
import XCTest

/// The status line and Claude Code's own snapshot both report Claude's plan limits, in no
/// particular order.
final class UsageLimitsMergeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { start.addingTimeInterval(3 * 60 * 60) }

    func testTheFirstReportIsTaken() {
        var engine = SessionStateEngine()
        XCTAssertTrue(engine.mergeUsageLimits(limits(fiveHour: 20, at: start)))
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour?.usedPercentage, 20)
    }

    /// The snapshot is often older than the status line that already arrived.
    func testAnOlderReportDoesNotReplaceANewerOne() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 30, at: start))

        XCTAssertFalse(engine.mergeUsageLimits(limits(fiveHour: 20, at: start.addingTimeInterval(-60))))
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour?.usedPercentage, 30)
    }

    /// The status line does not carry the reset time across the socket; the snapshot's stays.
    func testANewerReportWithoutAResetTimeKeepsTheKnownOne() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 20, resetsAt: resets, at: start))

        engine.mergeUsageLimits(limits(fiveHour: 25, at: start.addingTimeInterval(60)))

        XCTAssertEqual(
            engine.usageLimitsBySource[.claude]?.fiveHour,
            UsageWindow(usedPercentage: 25, resetsAt: resets))
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.observedAt, start.addingTimeInterval(60))
    }

    /// A window that has started again since says nothing about the new one's end.
    func testAResetTimeAlreadyPassedIsNotCarried() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 90, resetsAt: resets, at: start))

        engine.mergeUsageLimits(limits(fiveHour: 2, at: resets.addingTimeInterval(60)))

        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour, UsageWindow(usedPercentage: 2))
    }

    /// The status line can carry one window without the other.
    func testAWindowANewerReportLeavesOutStaysUntilItResets() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(
            AgentUsageLimits(
                source: .claude,
                fiveHour: UsageWindow(usedPercentage: 20, resetsAt: resets),
                sevenDay: UsageWindow(usedPercentage: 40, resetsAt: start.addingTimeInterval(4 * 24 * 60 * 60)),
                observedAt: start))

        engine.mergeUsageLimits(limits(fiveHour: 25, at: start.addingTimeInterval(60)))

        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.sevenDay?.usedPercentage, 40)
    }

    func testAWindowWithoutAResetTimeIsNotKeptWhenLeftOut() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(
            AgentUsageLimits(
                source: .claude, fiveHour: UsageWindow(usedPercentage: 20), sevenDay: UsageWindow(usedPercentage: 40),
                observedAt: start))

        engine.mergeUsageLimits(limits(fiveHour: 25, at: start.addingTimeInterval(60)))

        XCTAssertNil(engine.usageLimitsBySource[.claude]?.sevenDay)
    }

    func testTheSameReportAgainChangesNothing() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 20, resetsAt: resets, at: start))
        XCTAssertFalse(engine.mergeUsageLimits(limits(fiveHour: 20, resetsAt: resets, at: start)))
    }

    /// The status line goes through the same rule: a late one cannot undo a newer snapshot.
    func testALateStatusLineDoesNotReplaceANewerSnapshot() throws {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 40, resetsAt: resets, at: start))

        let late = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "StatusLine",
            payload: .object([
                "session_id": .string("id_session"),
                "five_hour_used_percentage": .number(35),
            ]),
            observedAt: start.addingTimeInterval(-30),
            clientKind: .cli
        )
        _ = try engine.ingest(late)

        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour?.usedPercentage, 40)
    }

    private func limits(fiveHour: Double, resetsAt: Date? = nil, at moment: Date) -> AgentUsageLimits {
        AgentUsageLimits(
            source: .claude,
            fiveHour: UsageWindow(usedPercentage: fiveHour, resetsAt: resetsAt),
            observedAt: moment)
    }
}
