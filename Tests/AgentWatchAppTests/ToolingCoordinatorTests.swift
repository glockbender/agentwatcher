import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// Installing an agent's records, and what the widget is entitled to say while none are
/// installed.
///
/// These two used to sit in `AppDelegate` with one calling the other, which is why the
/// complaint could be right in the app and absent from the screen. The coordinator states
/// both in one place: a change is made, and whoever is listening is told to look again.
@MainActor
final class ToolingCoordinatorTests: XCTestCase {
    func testInstallingTheRecordsForOneAgentIsAnnouncedAndReported() throws {
        let (coordinator, _) = try makeCoordinator()
        var logged: [String] = []
        var changes = 0
        coordinator.onLog = { logged.append($0) }
        coordinator.onChange = { changes += 1 }

        coordinator.press(.integration(ToolingIntegration(source: .claude, kind: .hooks)))

        XCTAssertEqual(coordinator.hookState(for: .claude), .unheard)
        XCTAssertEqual(changes, 1, "whoever draws the widget has to be told to look again")
        XCTAssertEqual(logged, [hooksInstalledMessage(for: .claude)])
    }

    func testPressingTheSameIntegrationAgainTakesTheRecordsBackOut() throws {
        let (coordinator, _) = try makeCoordinator()
        coordinator.press(.integration(ToolingIntegration(source: .claude, kind: .hooks)))

        coordinator.press(.integration(ToolingIntegration(source: .claude, kind: .hooks)))

        XCTAssertEqual(coordinator.hookState(for: .claude), .absent)
    }

    /// The widget's own line while nothing can report to it, and the step after: records are
    /// in place but nothing has come through them yet, which is a different thing to say and
    /// a different thing to do about it.
    ///
    /// It goes quiet only once something has actually arrived — installing is a promise, and
    /// the widget stops asking when the promise is kept.
    func testTheComplaintFollowsWhatIsActuallyInstalled() throws {
        let (coordinator, _) = try makeCoordinator()
        let nothingInstalled = coordinator.complaint()
        XCTAssertNotNil(nothingInstalled, "nothing is installed, so the widget has to say so")

        coordinator.press(.integration(ToolingIntegration(source: .claude, kind: .hooks)))

        XCTAssertNotEqual(
            coordinator.complaint(), nothingInstalled,
            "the records are in place now, and that is not the same problem"
        )
        XCTAssertEqual(coordinator.complaint(), toolingComplaint(states: [.unheard, .absent]))
    }

    /// A change that could not be made is still a change to what the widget should say: the
    /// fault it was meant to clear is still standing.
    func testAChangeThatFailedIsSaidOutLoudAndStillAsksForARedraw() throws {
        let (coordinator, home) = try makeCoordinator()
        // A directory where the hooks file has to go makes the write impossible.
        let hooksPath = ToolingInstaller(home: home).hooksPath(for: .claude)
        try FileManager.default.createDirectory(
            at: hooksPath, withIntermediateDirectories: true)
        var logged: [String] = []
        var changes = 0
        coordinator.onLog = { logged.append($0) }
        coordinator.onChange = { changes += 1 }

        coordinator.press(.integration(ToolingIntegration(source: .claude, kind: .hooks)))

        XCTAssertEqual(changes, 1)
        XCTAssertTrue(
            logged.contains { $0.hasPrefix("Tooling change failed") },
            "a change that silently did nothing is the one outcome nobody can diagnose: \(logged)"
        )
    }

    private func makeCoordinator() throws -> (ToolingCoordinator, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (
            ToolingCoordinator(
                installer: ToolingInstaller(home: home),
                heard: AgentHeardStore(directoryURL: home)
            ),
            home
        )
    }
}
