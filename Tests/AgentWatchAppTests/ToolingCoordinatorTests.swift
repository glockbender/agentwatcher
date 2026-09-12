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

    func testStartupAndInstallationHandTheSameLinkToTheNextBuild() throws {
        let (first, home) = try makeCoordinator()
        let support = home.appendingPathComponent("support")
        let link = support.appendingPathComponent("AgentWatchSend")
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(first.refreshSenderLink(), link.path)
        for source in AgentSource.allCases {
            first.press(.integration(ToolingIntegration(source: source, kind: .hooks)))
        }

        let installer = ToolingInstaller(home: home)
        let hookFiles = AgentSource.allCases.map { installer.hooksPath(for: $0) }
        let originalHooks = try hookFiles.map { try Data(contentsOf: $0) }
        let executable = try makeExecutable(in: home.appendingPathComponent("next-build"))
        let second = ToolingCoordinator(
            installer: installer,
            heard: AgentHeardStore(directoryURL: home),
            sender: SenderLink(directoryURL: support),
            executableURL: executable
        )
        XCTAssertEqual(second.refreshSenderLink(), link.path)
        XCTAssertEqual(
            link.resolvingSymlinksInPath(),
            executable.deletingLastPathComponent().appendingPathComponent("AgentWatchSend").resolvingSymlinksInPath()
        )
        XCTAssertEqual(try hookFiles.map { try Data(contentsOf: $0) }, originalHooks)
        for source in AgentSource.allCases {
            let document = try JSONDecoder().decode(
                JSONValue.self, from: Data(contentsOf: installer.hooksPath(for: source)))
            XCTAssertEqual(Set(ToolingInstallation.senderPaths(inHooks: document, source: source).values), [link.path])
        }
    }

    private func makeCoordinator() throws -> (ToolingCoordinator, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let executable = try makeExecutable(in: home.appendingPathComponent("first-build"))
        return (
            ToolingCoordinator(
                installer: ToolingInstaller(home: home),
                heard: AgentHeardStore(directoryURL: home),
                sender: SenderLink(directoryURL: support),
                executableURL: executable
            ),
            home
        )
    }

    private func makeExecutable(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sender = directory.appendingPathComponent("AgentWatchSend")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: sender)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sender.path)
        return directory.appendingPathComponent("AgentWatch")
    }
}
