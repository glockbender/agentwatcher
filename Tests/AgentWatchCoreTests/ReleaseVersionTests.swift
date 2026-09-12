import AgentWatchCore
import XCTest

/// The one comparison the app and the IDE plugin both rely on.
final class ReleaseVersionTests: XCTestCase {
    /// `0.1.10` is later than `0.1.9`, and no comparison of strings will say so.
    func testVersionsCompareByNumberWhereTheyAreNumbers() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.9", than: "0.1.10"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.3", than: "0.1.3"))
        XCTAssertTrue(ReleaseVersion.isNewer("1.0", than: "0.9.9"))
    }

    /// A finished build is later than its own pre-release, and two pre-releases of one build
    /// compare by their tag. Tags are plain `vX.Y.Z` today; this says what happens the day one
    /// is not, so that somebody on a hand-installed pre-release is offered the finished build.
    func testAFinishedBuildIsLaterThanItsPreRelease() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.3.0", than: "0.3.0-beta"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.2.0-rc1", than: "0.2.0"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.2.0-rc2", than: "0.2.0-rc1"))
        XCTAssertTrue(ReleaseVersion.isNewer("0.2.0-rc1", than: "0.1.9"))
    }
}
