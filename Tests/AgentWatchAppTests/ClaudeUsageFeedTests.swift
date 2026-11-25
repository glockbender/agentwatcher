import AgentWatchCore
import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchApp

/// When the app reads Claude Code's snapshot and when it starts Claude Code to ask.
///
/// Every run is a session in the organisation's metrics, so most of these are about the runs
/// that must not happen.
@MainActor
final class ClaudeUsageFeedTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let file = URL(fileURLWithPath: "/nonexistent/.claude.json")

    func testTheSnapshotIsReadWhenTheFileChangesAndNotAgainUntilItDoes() async {
        let reads = Counter()
        let modified = Box(start)
        let contents = Self.snapshotFile(fetchedAt: start)
        let feed = ClaudeUsageFeed(
            configFile: file, ask: nil, now: { self.start.addingTimeInterval(60) },
            modificationDate: { _ in modified.value },
            readFile: { _ in
                reads.increment()
                return contents
            })
        var delivered: [AgentUsageLimits] = []

        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: false) { delivered.append($0) }
        await settle(feed)
        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: false) { delivered.append($0) }
        await settle(feed)

        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(delivered.map(\.fiveHour?.usedPercentage), [18])

        modified.value = start.addingTimeInterval(30)
        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: false) { delivered.append($0) }
        await settle(feed)
        XCTAssertEqual(reads.value, 2)
    }

    func testRunsOnceWhenClaudeWorksAndNothingRecentIsKnown() async {
        let asks = Counter()
        let feed = makeFeed(asks: asks, reply: .limits(limits(at: start)))
        var delivered: [AgentUsageLimits] = []

        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { delivered.append($0) }
        await settle(feed)

        XCTAssertEqual(asks.value, 1)
        XCTAssertEqual(delivered, [limits(at: start)])
    }

    /// A run that brought nothing back still counts: the next sweep, fifteen seconds later,
    /// must not start another.
    func testAFailedRunHoldsTheNextOneForTheWholeInterval() async {
        let asks = Counter()
        let clock = Box(start)
        let feed = makeFeed(asks: asks, reply: nil, now: { clock.value })

        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
        await settle(feed)
        clock.value = start.addingTimeInterval(SessionSupervisor.maintenanceInterval)
        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
        await settle(feed)
        XCTAssertEqual(asks.value, 1)

        clock.value = start.addingTimeInterval(ClaudeUsageProbePolicy.interval)
        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
        await settle(feed)
        XCTAssertEqual(asks.value, 2)
    }

    func testARefusalStopsTheRunsUntilARestart() async {
        for reply: ClaudeUsageSnapshot.Reply in [.refused, .noPlanLimits, .unknownShape] {
            let asks = Counter()
            let clock = Box(start)
            let feed = makeFeed(asks: asks, reply: reply, now: { clock.value })

            feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
            await settle(feed)
            clock.value = start.addingTimeInterval(10 * ClaudeUsageProbePolicy.interval)
            feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
            await settle(feed)

            XCTAssertEqual(asks.value, 1, "after \(reply)")
        }
    }

    func testNothingRunsWhileNoClaudeSessionWorks() async {
        let asks = Counter()
        let feed = makeFeed(asks: asks, reply: .limits(limits(at: start)))

        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: false) { _ in }
        await settle(feed)

        XCTAssertEqual(asks.value, 0)
    }

    /// A report from a minute ago is fresh enough to skip a run.
    func testNothingRunsWhileRecentLimitsAreKnown() async {
        let asks = Counter()
        let feed = makeFeed(asks: asks, reply: .limits(limits(at: start)))

        feed.tick(knownLimitsObservedAt: { self.start.addingTimeInterval(-60) }, claudeIsWorking: true) { _ in }
        await settle(feed)

        XCTAssertEqual(asks.value, 0)
    }

    /// Right after a launch the app knows of no limits until the first read lands; a snapshot
    /// two minutes old must stop the run that the empty state would otherwise start.
    func testAFreshSnapshotReadOnTheFirstSweepPreventsARun() async {
        let asks = Counter()
        let contents = Self.snapshotFile(fetchedAt: start.addingTimeInterval(-120))
        let moment = start
        let feed = ClaudeUsageFeed(
            configFile: file,
            ask: {
                asks.increment()
                return nil
            },
            now: { moment },
            modificationDate: { _ in moment },
            readFile: { _ in contents })
        var known: AgentUsageLimits?

        feed.tick(knownLimitsObservedAt: { known?.observedAt }, claudeIsWorking: true) { known = $0 }
        await settle(feed)

        XCTAssertNotNil(known)
        XCTAssertEqual(asks.value, 0)
    }

    /// Offline, Claude Code answers without limits; the next attempt still comes on time.
    func testAReplyWithoutLimitsThisTimeDoesNotStopTheRuns() async {
        let asks = Counter()
        let clock = Box(start)
        let feed = makeFeed(asks: asks, reply: .unavailableNow, now: { clock.value })

        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
        await settle(feed)
        clock.value = start.addingTimeInterval(ClaudeUsageProbePolicy.interval)
        feed.tick(knownLimitsObservedAt: { nil }, claudeIsWorking: true) { _ in }
        await settle(feed)

        XCTAssertEqual(asks.value, 2)
    }

    /// The app's own run is a headless Claude Code; it must not count as the work that
    /// justifies the next one.
    func testOnlyAPersonsWorkingClaudeSessionCounts() {
        let now = start
        XCTAssertTrue(
            SessionSupervisor.claudeIsWorking([
                testSession(source: .claude, phase: .executing, clientKind: .cli, lastObservedAt: now)
            ]))
        XCTAssertFalse(
            SessionSupervisor.claudeIsWorking([
                testSession(source: .claude, phase: .executing, clientKind: .headless, lastObservedAt: now)
            ]))
        XCTAssertFalse(
            SessionSupervisor.claudeIsWorking([
                testSession(source: .codex, phase: .executing, clientKind: .cli, lastObservedAt: now)
            ]))
        XCTAssertFalse(
            SessionSupervisor.claudeIsWorking([
                testSession(source: .claude, phase: .completed, clientKind: .cli, lastObservedAt: now)
            ]))
    }

    // MARK: - Helpers

    private func makeFeed(
        asks: Counter,
        reply: ClaudeUsageSnapshot.Reply?,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> ClaudeUsageFeed {
        ClaudeUsageFeed(
            configFile: file,
            ask: {
                asks.increment()
                return reply
            },
            now: now,
            modificationDate: { _ in nil },
            readFile: { _ in nil })
    }

    private func settle(_ feed: ClaudeUsageFeed) async {
        for _ in 0..<400 where feed.reading || feed.probing {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(feed.reading || feed.probing, "the feed never settled")
    }

    private func limits(at moment: Date) -> AgentUsageLimits {
        AgentUsageLimits(source: .claude, fiveHour: UsageWindow(usedPercentage: 21), observedAt: moment)
    }

    nonisolated private static func snapshotFile(fetchedAt: Date) -> Data {
        Data(
            """
            {"cachedUsageUtilization":{"fetchedAtMs":\(Int(fetchedAt.timeIntervalSince1970 * 1000)),
             "utilization":{"five_hour":{"utilization":18,"resets_at":null}}}}
            """.utf8)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
