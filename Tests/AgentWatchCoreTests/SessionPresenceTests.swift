import AgentWatchTestSupport
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
        XCTAssertEqual(SessionPresence.dismissal(of: snapshot(phase: .sessionClosed), now: now), .now)
        XCTAssertEqual(SessionPresence.dismissal(of: snapshot(phase: .disconnected), now: now), .now)

        // Waiting for a person is not tracked for freshness — an answer can take an hour — so
        // without the silence rule a session waiting on a completion that never came would
        // blink for attention with nothing able to clear it.
        XCTAssertEqual(
            SessionPresence.dismissal(of: snapshot(phase: .waitingForUser), now: now),
            .notOffered(until: now + SessionFreshnessEvaluator.defaultDisconnectAfter))
        var longSilent = snapshot(phase: .waitingForUser)
        longSilent.lastObservedAt = now - SessionFreshnessEvaluator.defaultDisconnectAfter
        XCTAssertEqual(SessionPresence.dismissal(of: longSilent, now: now), .now)

        // A fault waits out nothing: every case above waits because the app still believes
        // the row, and a fault is the app saying it does not.
        var faulted = snapshot(phase: .executing)
        faulted.monitoringFault = .transcriptNotFound
        XCTAssertEqual(SessionPresence.dismissal(of: faulted, now: now), .now)
    }

    /// The half of the answer the old `Bool` could not carry: a row whose session has
    /// finished offers its `×` greyed, with the moment it starts working — and a row still
    /// live offers none at all, `idle` included: resting between turns is not finished.
    func testARowThatIsOverButStillHeldSaysWhenItsButtonStartsWorking() {
        for phase in [SessionPhase.completed, .failed] {
            XCTAssertEqual(
                SessionPresence.dismissal(of: snapshot(phase: phase), now: now),
                .notYet(at: now + SessionFreshnessEvaluator.defaultDisconnectAfter),
                "\(phase) is over, so the button is offered — greyed until then"
            )
        }

        for phase in [SessionPhase.planning, .executing, .waitingForChildren, .waitingForUser, .idle] {
            XCTAssertEqual(
                SessionPresence.dismissal(of: snapshot(phase: phase), now: now),
                .notOffered(until: now + SessionFreshnessEvaluator.defaultDisconnectAfter),
                "\(phase) is live work, and a button for it would promise something else"
            )
        }
    }

    /// Every phase lands in exactly one of the three, and the two that mean "no button now"
    /// are never the same answer — the whole point of splitting the old `Bool` in two.
    func testEveryPhaseGetsOneOfTheThreeAnswers() {
        for phase in allPhases {
            let answer = SessionPresence.dismissal(of: snapshot(phase: phase), now: now)
            switch answer {
            case .now:
                XCTAssertNil(answer.becomesDismissibleAt, "\(phase) already offers a working button")
            case .notYet(let at), .notOffered(let at):
                XCTAssertEqual(at, now + SessionFreshnessEvaluator.defaultDisconnectAfter, "\(phase)")
                XCTAssertEqual(answer.becomesDismissibleAt, at, "\(phase)")
            }
        }
    }

    private var allPhases: [SessionPhase] {
        [
            .idle, .planning, .executing, .waitingForUser, .waitingForChildren,
            .completed, .failed, .disconnected, .sessionClosed,
        ]
    }

    private func snapshot(phase: SessionPhase) -> SessionSnapshot {
        testSession(mode: .standard, phase: phase, lastObservedAt: now)
    }
}
