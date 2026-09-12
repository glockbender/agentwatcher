import XCTest

@testable import AgentWatchCore

final class TranscriptReadScheduleTests: XCTestCase {
    private let schedule = TranscriptReadSchedule(floor: 5, idle: 10, coalesceWindow: 0.5)
    private let lastRead = Date(timeIntervalSince1970: 1_000)

    func testFirstHookAtTheSchedulingAnchorHasNotAlreadyBeenRead() {
        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: lastRead, isFirstRead: true),
            lastRead + 5
        )
    }

    func testWithNoHookTheNextReadFallsOnTheIdleInterval() {
        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: nil),
            lastRead.addingTimeInterval(10)
        )
    }

    func testAHookLongAfterTheLastReadPullsTheReadForwardToJustAfterItself() {
        let hook = lastRead.addingTimeInterval(7)

        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: hook),
            hook.addingTimeInterval(0.5)
        )
    }

    func testAHookArrivingJustAfterAReadWaitsOutTheFloorRatherThanReadingAgain() {
        let hook = lastRead.addingTimeInterval(0.2)

        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: hook),
            lastRead.addingTimeInterval(5)
        )
    }

    func testAHookNeverPushesAnAlreadyDueReadLater() {
        let hook = lastRead.addingTimeInterval(9.8)

        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: hook),
            lastRead.addingTimeInterval(10)
        )
    }

    func testOneHookOnlyAcceleratesTheFirstReadThatCoversIt() {
        let hook = lastRead + 1
        let first = schedule.nextRead(lastReadAt: lastRead, lastHookAt: hook)
        let second = schedule.nextRead(lastReadAt: first, lastHookAt: hook)
        let third = schedule.nextRead(lastReadAt: second, lastHookAt: hook)

        XCTAssertEqual(first, lastRead + 5)
        XCTAssertEqual(second, first + 10)
        XCTAssertEqual(third, second + 10)
        XCTAssertEqual(schedule.nextRead(lastReadAt: hook, lastHookAt: hook), hook + 10)
    }

    func testAHookArrivingDuringAReadStillAcceleratesTheFollowingRead() {
        // lastReadAt is the read's start, not the time its background work finishes.
        XCTAssertEqual(
            schedule.nextRead(lastReadAt: lastRead, lastHookAt: lastRead + 2),
            lastRead + 5
        )
    }
}
