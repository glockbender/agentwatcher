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
}
