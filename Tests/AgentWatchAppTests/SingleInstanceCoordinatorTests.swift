import Foundation
import XCTest

@testable import AgentWatchApp

/// One socket name means one Agent Watch. The lock is what holds that, and a lock that fails
/// open would be invisible: the second window fills with nothing and explains nothing.
final class SingleInstanceCoordinatorTests: XCTestCase {
    func testASecondCoordinatorIsRefused() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let first = SingleInstanceCoordinator(directoryURL: directoryURL)
        let second = SingleInstanceCoordinator(directoryURL: directoryURL)

        XCTAssertTrue(first.mayLaunch())
        XCTAssertFalse(second.mayLaunch())
        XCTAssertEqual(first.socketURL()?.lastPathComponent, "agent-watch.sock")
    }

    /// Without this the name stays taken after the app that held it is gone, and the next
    /// launch is refused for a process that no longer exists.
    func testReleasingTheCoordinatorReleasesTheLock() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var first: SingleInstanceCoordinator? = SingleInstanceCoordinator(directoryURL: directoryURL)

        XCTAssertTrue(first?.mayLaunch() == true)
        first = nil

        let second = SingleInstanceCoordinator(directoryURL: directoryURL)
        XCTAssertTrue(second.mayLaunch())
    }

    private func makeTemporaryDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }
}
