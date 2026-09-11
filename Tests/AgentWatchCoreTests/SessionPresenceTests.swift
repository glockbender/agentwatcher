import Foundation
import XCTest

@testable import AgentWatchCore

/// These two rules used to live as statics on the row that drew them, reachable only through
/// the AppKit target. Here they are, being exercised without one.
final class SessionPresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Two rules answered the same question with their own switch, in opposite directions,
    /// and nothing checked that they agreed. Now one of them is the definition — so this is
    /// what would catch a phase classified one way here and the other way there.
    func testSilenceAndFreshnessAgreeOnEveryPhase() {
        for phase in allPhases {
            var snapshot = snapshot(phase: phase)
            snapshot.phase = phase
            XCTAssertEqual(
                SessionSilence.isExpected(snapshot),
                !SessionFreshnessEvaluator.tracksFreshness(for: phase),
                "\(phase) is classified differently by the two rules"
            )
        }
    }

    func testARowTheAppWillNeverRevisitOnItsOwnCanBeDismissedByHand() {
        XCTAssertTrue(SessionPresence.isDismissible(snapshot(phase: .sessionClosed), now: now))
        XCTAssertTrue(SessionPresence.isDismissible(snapshot(phase: .disconnected), now: now))

        // Waiting for a person is not tracked for freshness — an answer can take an hour — so
        // without the silence rule a session waiting on a completion that never came would
        // blink for attention with nothing able to clear it.
        XCTAssertFalse(SessionPresence.isDismissible(snapshot(phase: .waitingForUser), now: now))
        var longSilent = snapshot(phase: .waitingForUser)
        longSilent.lastObservedAt = now - SessionFreshnessEvaluator.defaultDisconnectAfter
        XCTAssertTrue(SessionPresence.isDismissible(longSilent, now: now))

        // A fault waits out nothing: every case above waits because the app still believes
        // the row, and a fault is the app saying it does not.
        var faulted = snapshot(phase: .executing)
        faulted.monitoringFault = .transcriptNotFound
        XCTAssertTrue(SessionPresence.isDismissible(faulted, now: now))
    }

    private var allPhases: [SessionPhase] {
        [
            .idle, .planning, .executing, .waitingForUser, .waitingForChildren,
            .completed, .failed, .disconnected, .sessionClosed,
        ]
    }

    /// The one row `↗` can never reach. Every other kind keeps a pressable button, because
    /// where its host is can change between two presses and a grey button cannot.
    func testOnlyABackgroundSessionCanNeverBeBroughtForward() {
        var session = snapshot(phase: .executing)

        session.clientKind = .background
        XCTAssertFalse(SessionPresence.canBeBroughtForward(session))

        session.clientKind = .cli
        XCTAssertTrue(SessionPresence.canBeBroughtForward(session))

        session.clientKind = .desktop
        XCTAssertTrue(SessionPresence.canBeBroughtForward(session))

        session.clientKind = nil
        XCTAssertTrue(
            SessionPresence.canBeBroughtForward(session),
            "a session that never said where it runs is not a session known to be unreachable"
        )
    }

    private func snapshot(phase: SessionPhase) -> SessionSnapshot {
        SessionSnapshot(
            id: "session-1",
            source: .claude,
            arrivalIndex: 0,
            mode: .standard,
            phase: phase,
            lastObservedAt: now
        )
    }
}
