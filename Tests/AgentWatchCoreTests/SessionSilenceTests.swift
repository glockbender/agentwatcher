import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// The rule that separates "nothing is happening because nothing should be" from "nothing is
/// happening and nobody can say why". It decides both when there is any point reading a
/// transcript and when the widget admits it has lost track.
final class SessionSilenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 4_000)
    private var now: Date { start.addingTimeInterval(1_000) }

    func testAPhaseThatAccountsForItsOwnQuietIsNotWorthWatching() {
        for phase in [SessionPhase.idle, .waitingForUser, .completed, .failed, .disconnected, .sessionClosed] {
            XCTAssertTrue(SessionSilence.isExpected(snapshot(phase: phase)), "\(phase) explains itself")
        }
        for phase in [SessionPhase.planning, .executing, .waitingForChildren] {
            XCTAssertFalse(SessionSilence.isExpected(snapshot(phase: phase)), "\(phase) claims work")
        }
    }

    /// Two questions that used to be one. Whether quiet is a fault has not changed: a person
    /// answering a dialog takes as long as they take. Whether quiet is worth reading has — a
    /// dialog dismissed with Esc writes `[Request interrupted by user for tool use]` into the
    /// transcript and fires no hook, so the wait can end with nobody announcing it, and a
    /// reader that skipped the waiting row left it asking for an approval long withdrawn.
    func testAWaitForAPersonIsWorthReadingThoughItsQuietIsNoFault() {
        let waiting = snapshot(phase: .waitingForUser)

        XCTAssertTrue(SessionSilence.isExpected(waiting), "nothing to blame the session for")
        XCTAssertTrue(SessionSilence.mayEndWithoutAHook(waiting), "and yet something to look for")

        for phase in [SessionPhase.planning, .executing, .waitingForChildren] {
            XCTAssertTrue(SessionSilence.mayEndWithoutAHook(snapshot(phase: phase)), "\(phase)")
        }
        for phase in [SessionPhase.idle, .completed, .failed, .disconnected, .sessionClosed] {
            XCTAssertFalse(SessionSilence.mayEndWithoutAHook(snapshot(phase: phase)), "\(phase) ends only by a hook")
        }
    }

    /// The whole point of the open-activity condition. A build running for an hour is silent
    /// and completely explained: the call is right there in the session's list. Reporting it
    /// would fire the warning on healthy sessions, which is how a warning gets ignored.
    func testALongRunningCommandIsNotAFault() {
        let building = snapshot(phase: .executing, activities: [call(id: "call-1")])

        XCTAssertFalse(SessionSilence.isUnexplained(building, now: start + 3_600))
    }

    func testASessionThatClaimsWorkWithNothingRunningIsAFault() {
        let stalled = snapshot(phase: .executing)

        XCTAssertTrue(SessionSilence.isUnexplained(stalled, now: start + 120))
    }

    /// A turn spent thinking rather than calling anything looks exactly like the fault, and
    /// is ordinary. The threshold is what keeps the two apart.
    func testThinkingIsGivenTimeBeforeItCountsAsAFault() {
        let thinking = snapshot(phase: .executing)

        XCTAssertFalse(SessionSilence.isUnexplained(thinking, now: start + 119))
    }

    func testAnIdleSessionIsNeverAFaultHoweverLongItSits() {
        let resting = snapshot(phase: .idle)

        XCTAssertFalse(SessionSilence.isUnexplained(resting, now: start + 86_400))
    }

    /// A person answering a permission dialog takes as long as they take, and the widget's
    /// job while they do is to keep asking — not to start doubting itself.
    func testWaitingForAPersonIsNeverAFault() {
        let waiting = snapshot(phase: .waitingForUser)

        XCTAssertFalse(SessionSilence.isUnexplained(waiting, now: start + 86_400))
    }

    func testANonPositiveThresholdReportsNothing() {
        let stalled = snapshot(phase: .executing)

        XCTAssertFalse(SessionSilence.isUnexplained(stalled, now: start + 86_400, after: 0))
    }

    // MARK: - Helpers

    private func snapshot(phase: SessionPhase, activities: [SessionActivity] = []) -> SessionSnapshot {
        testSession(phase: phase, activities: activities, lastObservedAt: start)
    }

    private func call(id: String) -> SessionActivity {
        SessionActivity(id: id, kind: .shell, startedAt: start)
    }

    /// The four-level precedence that decides whether a quiet row gets a warning triangle.
    /// It used to live inside the transcript reader, in the AppKit target, stated in prose
    /// and reachable by no test — while `AGENTS.md` asks for exactly this kind of rule to be
    /// checkable without launching an application.
    func testSilenceIsOnlyAFaultWhenNothingElseAlreadyExplainsTheQuiet() {
        var quiet = snapshot(phase: .executing)
        quiet.lastObservedAt = now - SessionSilence.defaultUnexplainedAfter - 1

        XCTAssertEqual(
            SessionSilence.fault(for: quiet, alreadyFaulted: false, sawFreshRecord: false, isBeingRead: true, now: now),
            .unexplainedSilence
        )

        // A fault from the reading itself says why nothing is known, which is a better answer
        // than saying nothing is known.
        XCTAssertNil(
            SessionSilence.fault(for: quiet, alreadyFaulted: true, sawFreshRecord: false, isBeingRead: true, now: now)
        )
        // Anything read this tick settles the question: the snapshot is one publish old, so a
        // session just heard from still looks as quiet as it was a moment ago.
        XCTAssertNil(
            SessionSilence.fault(for: quiet, alreadyFaulted: false, sawFreshRecord: true, isBeingRead: true, now: now)
        )
        // A session with no file in hand is not being read at all, so its age stops moving for
        // that reason alone. Calling that silence would replace the honest complaint on the
        // row with a wrong one.
        XCTAssertNil(
            SessionSilence.fault(for: quiet, alreadyFaulted: false, sawFreshRecord: false, isBeingRead: false, now: now)
        )

        var working = snapshot(phase: .executing)
        working.lastObservedAt = now
        XCTAssertNil(
            SessionSilence.fault(
                for: working, alreadyFaulted: false, sawFreshRecord: false, isBeingRead: true, now: now)
        )
    }
}
