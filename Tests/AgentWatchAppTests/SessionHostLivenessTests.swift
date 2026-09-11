import AgentWatchCore
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

    private func session(_ configure: (inout SessionSnapshot) -> Void) -> SessionSnapshot {
        var session = testSession(lastObservedAt: moment)
        configure(&session)
        return session
    }
}
