import AppKit
import XCTest

@testable import AgentWatchApp

/// Work asked for many times in one turn of the run loop is done once, and the settings window
/// lets go of its pages when it closes. Both answer the same measurement: a dragged colour
/// wheel took the app from 92 MB to 373 MB (`docs/measurements.md`).
@MainActor
final class CoalescedWorkTests: XCTestCase {
    func testManyRequestsInOneTurnRunTheWorkOnceOnTheNext() {
        var runs = 0
        let work = CoalescedWork { runs += 1 }

        for _ in 0..<120 {
            work.request()
        }
        XCTAssertEqual(runs, 0, "nothing is done in the turn that asks")

        nextTurn()
        XCTAssertEqual(runs, 1)

        work.request()
        nextTurn()
        XCTAssertEqual(runs, 2, "a request after the work ran is a new one")
    }

    /// A caller that has to see the result at once gets it, and the turn after does not do it
    /// again.
    func testPendingWorkCanBeDoneAtOnce() {
        var runs = 0
        let work = CoalescedWork { runs += 1 }

        work.request()
        work.runIfPending()
        XCTAssertEqual(runs, 1)

        nextTurn()
        XCTAssertEqual(runs, 1)
        work.runIfPending()
        XCTAssertEqual(runs, 1, "nothing was pending")
    }

    /// Lets the main queue run what it holds. It runs its blocks in order, so everything asked
    /// for before this has run once it returns — which spinning the run loop for a while does
    /// not promise: with nothing else to wait on, it can return at once.
    private func nextTurn() {
        let done = expectation(description: "the main queue has run what it held")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
