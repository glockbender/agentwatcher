import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// Whether a remembered session's agent is still there. Restoring a row nothing can vouch
/// for would put a session in the widget that ended while the app was not running.
@MainActor
final class SessionHostLivenessTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_700_000_000)

    /// A desktop session is vouched for by its application and never by its process. Codex
    /// leaves helper processes behind when it quits — the reason `agentApplicationTerminated`
    /// exists — so a PID check would report a session as live because a helper of a dead app
    /// is still running.
    func testADesktopSessionIsVouchedForByItsApplication() {
        var session = testSession(source: .codex, clientKind: .desktop, lastObservedAt: moment)
        session.agentProcessID = 4_242

        XCTAssertTrue(
            SessionHostRegistry.isHostAlive(
                session,
                processStartedAt: { _ in self.moment - 60 },
                isApplicationRunning: { _ in true }
            )
        )
        XCTAssertFalse(
            SessionHostRegistry.isHostAlive(
                session,
                processStartedAt: { _ in self.moment - 60 },
                isApplicationRunning: { _ in false }
            ),
            "a live helper process must not vouch for an application that has quit"
        )
    }

    /// A PID is not an identity. macOS reuses them, and a laptop that ran overnight will have
    /// wrapped around, so a remembered session can name a number that now belongs to
    /// something else entirely. A process that started after the session was last heard from
    /// cannot be the one that was sending those events.
    func testAProcessIsOnlyEvidenceIfItIsOlderThanTheLastThingHeard() {
        let cliSession = session {
            $0.clientKind = .cli
            $0.agentProcessID = 4_242
        }

        XCTAssertTrue(
            SessionHostRegistry.isHostAlive(
                cliSession,
                processStartedAt: { _ in self.moment - 3_600 },
                isApplicationRunning: { _ in false }
            )
        )
        XCTAssertFalse(
            SessionHostRegistry.isHostAlive(
                cliSession,
                processStartedAt: { _ in self.moment + 1 },
                isApplicationRunning: { _ in false }
            ),
            "a process younger than the session's own last event is somebody else's"
        )
        XCTAssertFalse(
            SessionHostRegistry.isHostAlive(
                cliSession,
                processStartedAt: { _ in nil },
                isApplicationRunning: { _ in false }
            ),
            "and a process the kernel will not name is gone"
        )
    }

    /// Nothing to ask, so nothing is claimed. A row the app cannot vouch for is worse than a
    /// missing one: it says a session is there, and nothing will ever take it away.
    func testASessionWithNothingToVouchForItIsNotRestored() {
        XCTAssertFalse(
            SessionHostRegistry.isHostAlive(
                session { $0.clientKind = .cli },
                processStartedAt: { _ in self.moment - 3_600 },
                isApplicationRunning: { _ in true }
            )
        )
    }

    /// Asking where a session is must never be what puts it beyond the sweep's reach.
    ///
    /// `watchedSessionIDs` is the registry's record of which sessions have a process-exit
    /// watch, and the engine reads it as "somebody will report this one's death" — so a
    /// session in it is one `markUnwatchedSessionsDisconnected` leaves alone. `associate`
    /// declines a Codex session, because a PID cannot vouch for a client whose application
    /// hosts many threads in one process. A hover that created the record anyway would put
    /// that session into the set with nothing watching it, and nothing left to retire it.
    func testHoveringASessionTheRegistryDeclinedDoesNotGiveItAWatchItDoesNotHave() {
        let registry = SessionHostRegistry { _ in }
        var codex = testSession(source: .codex, clientKind: .cli, lastObservedAt: Date())
        // A number this process really holds, so the tree above it is walkable and the first
        // branch of `application(for:)` is actually taken.
        codex.agentProcessID = getpid()

        registry.associate(codex)
        _ = registry.locator(for: codex)
        _ = registry.focus(codex)

        XCTAssertTrue(
            registry.watchedSessionIDs.isEmpty,
            "a session nothing is watching must stay visible to the sweep"
        )
    }

    /// The same rule, now asked by name, because two paths need it and only one used to ask.
    ///
    /// Vouching for a remembered row asked it. Deciding which application to raise did not,
    /// and walked the tree from whatever process now holds the number — so a session whose
    /// agent had exited could hand the `↗` button a stranger's application to bring forward.
    func testWhetherTheNumberIsStillTheAgentIsOneRuleBothPathsAsk() {
        XCTAssertTrue(
            SessionHostRegistry.isStillTheAgent(
                agentProcessID: 4_242,
                lastObservedAt: moment,
                processStartedAt: { _ in self.moment - 3_600 }
            )
        )
        XCTAssertFalse(
            SessionHostRegistry.isStillTheAgent(
                agentProcessID: 4_242,
                lastObservedAt: moment,
                processStartedAt: { _ in self.moment + 1 }
            ),
            "a process younger than the session's last event is a reused number"
        )
        XCTAssertFalse(
            SessionHostRegistry.isStillTheAgent(
                agentProcessID: 4_242,
                lastObservedAt: moment,
                processStartedAt: { _ in nil }
            ),
            "and a number the kernel will not name holds nothing"
        )
    }

    /// A background session's press opens a terminal tab with `claude attach` instead of
    /// raising a window, and the job to attach to is read from Claude Code's own record of
    /// the process. When there is no record, the outcome says so — the alternative is a
    /// press that does nothing and a log line that says only that.
    func testABackgroundSessionWithNoRecordOfItsProcessSaysSo() throws {
        let registry = SessionHostRegistry(claudeHome: try temporaryClaudeHome()) { _ in }
        var background = testSession(clientKind: .background, lastObservedAt: moment)
        background.agentProcessID = 4_242

        let outcome = registry.focus(background)

        XCTAssertFalse(outcome.raised)
        XCTAssertEqual(outcome.tab, .missing("Claude Code keeps no record of process 4242"))
    }

    /// An interactive session has a record too, with no job in it. Only a background session
    /// reaches this code, so a record without a job is Claude Code's file changing shape —
    /// worth a line that says which file, not a silent press.
    func testABackgroundSessionWhoseRecordNamesNoJobSaysSo() throws {
        let home = try temporaryClaudeHome()
        try Data(#"{"pid":"4242","kind":"interactive","name":"unnamed"}"#.utf8)
            .write(to: BackgroundSessionAttach.sessionRecordURL(claudeHome: home, agentProcessID: 4_242))
        let registry = SessionHostRegistry(claudeHome: home) { _ in }
        var background = testSession(clientKind: .background, lastObservedAt: moment)
        background.agentProcessID = 4_242

        let outcome = registry.focus(background)

        XCTAssertFalse(outcome.raised)
        XCTAssertEqual(outcome.tab, .missing("Claude Code's record of the process names no job to attach to"))
    }

    /// A `~/.claude` of this test's own, with the `sessions` folder Claude Code keeps there.
    private func temporaryClaudeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-watch-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
        }
        return home
    }

    private func session(_ configure: (inout SessionSnapshot) -> Void) -> SessionSnapshot {
        var session = testSession(lastObservedAt: moment)
        configure(&session)
        return session
    }
}
