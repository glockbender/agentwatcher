import XCTest

@testable import AgentWatchSender

final class AgentProcessScannerTests: XCTestCase {
    /// `launchd` is the oldest process on the machine, and the kernel lists processes newest
    /// first — so it is the last entry, and the first one a listing cut short would lose.
    /// A scanner that cannot see pid 1 cannot see an agent that has been running for a day.
    func testProcessListingReachesLaunchd() {
        let identifiers = AgentProcessScanner.allProcessIDs()

        XCTAssertTrue(identifiers.contains(1), "pid 1 missing from \(identifiers.count) listed processes")
        XCTAssertTrue(identifiers.contains(getpid()), "the test process itself is missing")
    }
}
