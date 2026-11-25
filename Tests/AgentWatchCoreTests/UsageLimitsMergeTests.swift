import AgentWatchCore
import XCTest

/// Plan limits can arrive from Claude Code's snapshot or a fresh query.
final class UsageLimitsMergeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var resets: Date { start.addingTimeInterval(3 * 60 * 60) }

    func testTheFirstReportIsTaken() {
        var engine = SessionStateEngine()
        XCTAssertTrue(engine.mergeUsageLimits(limits(fiveHour: 20, at: start)))
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour?.usedPercentage, 20)
    }

    func testAnOlderReportDoesNotReplaceANewerOne() {
        var engine = SessionStateEngine()
        engine.mergeUsageLimits(limits(fiveHour: 30, at: start))

        XCTAssertFalse(engine.mergeUsageLimits(limits(fiveHour: 20, at: start.addingTimeInterval(-60))))
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.fiveHour?.usedPercentage, 30)
    }

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

    private func limits(fiveHour: Double, resetsAt: Date? = nil, at moment: Date) -> AgentUsageLimits {
        AgentUsageLimits(
            source: .claude,
            fiveHour: UsageWindow(usedPercentage: fiveHour, resetsAt: resetsAt),
            observedAt: moment)
    }
}
