import XCTest

@testable import AgentWatchCore

final class TranscriptReadScheduleTests: XCTestCase {
    private let schedule = TranscriptReadSchedule(floor: 5, idle: 10, coalesceWindow: 0.5)
    private let lastRead = Date(timeIntervalSince1970: 1_000)

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
}
