import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// A real file in a real directory, written the way Claude Code writes it — measured on five
/// status changes across three sessions. A test that stubbed the file system would be
/// checking only the part that was never in doubt.
@MainActor
final class SessionRecordWatcherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_483_499)
    private let agentProcessID: Int32 = 22983

    private var inbox: [(sessionID: String, status: ClaudeSessionStatus)] = []

    private lazy var home: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchSessionRecordTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".claude/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }()

    /// The whole point of the change: the moment a person answers, Claude Code rewrites this
    /// file, and the row must not wait for the approved call to finish to hear about it.
    func testTheRecordLosingItsDialogIsReported() throws {
        try writeRecord(state: "waiting", waitingFor: "permission prompt", updatedAt: start)
        let watcher = makeWatcher()
        watcher.update(sessions: [waitingSession()])
        inbox = []

        try writeRecord(state: "busy", waitingFor: nil, updatedAt: start + 5)
        watcher.poll()

        XCTAssertEqual(inbox.last?.sessionID, waitingSession().id)
        XCTAssertEqual(inbox.last?.status.state, .busy)
        XCTAssertEqual(inbox.last?.status.updatedAt, start + 5)
    }

    /// The dialog may have been answered before this app was looking: it can be launched, or
    /// a row restored from the session memory, while the call the person approved is still
    /// running. So the first read happens on the way in rather than a tick later.
    func testTheRecordIsReadAsSoonAsARowStartsBeingWatched() throws {
        try writeRecord(state: "busy", waitingFor: nil, updatedAt: start + 5)
        let watcher = makeWatcher()

        watcher.update(sessions: [waitingSession()])

        XCTAssertEqual(inbox.last?.status.state, .busy)
    }

    /// Read twice a second and announced every time, this would be a heartbeat rather than a
    /// fact, and the debug log exists to show the handful of things that actually happened.
    func testARecordThatHasNotChangedIsAnnouncedOnce() throws {
        try writeRecord(state: "waiting", waitingFor: "permission prompt", updatedAt: start)
        let watcher = makeWatcher()
        watcher.update(sessions: [waitingSession()])

        watcher.poll()
        watcher.poll()

        XCTAssertEqual(inbox.count, 1)
    }

    /// `AGENTS.md` forbids polling while there is nothing to poll for. A session nobody is
    /// being asked about has no record worth opening.
    func testNothingIsWatchedWhileNoSessionWaitsForAPerson() throws {
        try writeRecord(state: "busy", waitingFor: nil, updatedAt: start)
        let watcher = makeWatcher()

        watcher.update(sessions: [workingSession()])

        XCTAssertFalse(watcher.isWatching)
        XCTAssertTrue(inbox.isEmpty)
    }

    /// And stops again on its own once the answer is in, without waiting for anything to tell
    /// it to. Otherwise the first dialog of a launch would leave a timer running for good.
    func testWatchingStopsWhenTheRowLeavesItsWait() throws {
        try writeRecord(state: "waiting", waitingFor: "permission prompt", updatedAt: start)
        let watcher = makeWatcher()
        watcher.update(sessions: [waitingSession()])
        XCTAssertTrue(watcher.isWatching)

        watcher.update(sessions: [workingSession()])

        XCTAssertFalse(watcher.isWatching)
    }

    /// The timer, and not only the reading it drives. Everything else here calls `poll`
    /// directly, which would go on passing if the timer had never been scheduled at all.
    func testTheTimerReadsTheRecordOnItsOwn() throws {
        try writeRecord(state: "waiting", waitingFor: "permission prompt", updatedAt: start)
        let watcher = makeWatcher()
        watcher.update(sessions: [waitingSession()])
        inbox = []

        try writeRecord(state: "busy", waitingFor: nil, updatedAt: start + 5)
        let deadline = Date().addingTimeInterval(3)
        while inbox.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(inbox.last?.status.state, .busy)
    }

    // MARK: - Helpers

    private func makeWatcher() -> SessionRecordWatcher {
        let watcher = SessionRecordWatcher(
            claudeHome: home.appendingPathComponent(".claude", isDirectory: true),
            onStatus: { [weak self] sessionID, status in
                self?.inbox.append((sessionID, status))
            }
        )
        let root = home
        addTeardownBlock {
            await MainActor.run { watcher.stop() }
            try? FileManager.default.removeItem(at: root)
        }
        return watcher
    }

    private func writeRecord(state: String, waitingFor: String?, updatedAt: Date) throws {
        let reason = waitingFor.map { "\"waitingFor\":\"\($0)\"," } ?? ""
        let milliseconds = Int(updatedAt.timeIntervalSince1970 * 1000)
        try Data(
            """
            {"pid":\(agentProcessID),"kind":"interactive","status":"\(state)",\
            \(reason)"statusUpdatedAt":\(milliseconds)}
            """.utf8
        ).write(to: recordURL)
    }

    private var recordURL: URL {
        home
            .appendingPathComponent(".claude/sessions", isDirectory: true)
            .appendingPathComponent("\(agentProcessID).json")
    }

    private func waitingSession() -> SessionSnapshot {
        session(phase: .waitingForUser)
    }

    private func workingSession() -> SessionSnapshot {
        session(phase: .executing)
    }

    private func session(phase: SessionPhase) -> SessionSnapshot {
        var snapshot = testSession(phase: phase, lastObservedAt: start)
        snapshot.agentProcessID = agentProcessID
        return snapshot
    }
}
