import Foundation
import XCTest

@testable import AgentWatchCore

/// The app writes these names and the hook sender looks for them, from a different target,
/// with nothing between them but agreement. So the agreement is the thing under test.
final class AgentWatchPathsTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

    func testTheAppAndTheSenderMeetAtOneName() {
        let directory = AgentWatchPaths.supportDirectory(inApplicationSupport: support)

        XCTAssertEqual(directory.lastPathComponent, "AgentWatch")
        XCTAssertEqual(AgentWatchPaths.socketURL(inDirectory: directory).lastPathComponent, "agent-watch.sock")
        XCTAssertEqual(
            AgentWatchPaths.socketURL(inDirectory: directory).deletingLastPathComponent(),
            directory,
            "the socket sits in the app's own folder, beside the lock that keeps it single"
        )
    }
}
