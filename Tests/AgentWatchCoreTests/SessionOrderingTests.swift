import AgentWatchTestSupport
import XCTest

@testable import AgentWatchCore

/// Whether a session has worked, which block it is in, and the order a list shows them in.
final class SessionOrderingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    // MARK: - Whether a session has worked

    func testASessionThatHasOnlyStartedHasNotWorked() {
        let started = SessionReducer.reduce(
            testSession(phase: .idle, lastObservedAt: start),
            event: .sessionStarted(mode: nil, at: start)
        )

        XCTAssertFalse(started.hasWorked)
    }

    /// Once is enough, and it is never taken back: finishing, resting, losing the signal and
    /// closing all leave a session that has worked.
    func testATurnMarksASessionAsHavingWorkedForGood() {
        var session = testSession(phase: .idle, lastObservedAt: start)
        session = SessionReducer.reduce(session, event: .turnStarted(mode: .standard, at: start))
        XCTAssertTrue(session.hasWorked)

        for event: SessionEvent in [
            .turnCompleted(at: start + 1),
            .sessionStarted(mode: nil, at: start + 2),
            .disconnected(at: start + 3),
            .sessionClosed(at: start + 4),
        ] {
            session = SessionReducer.reduce(session, event: event)
            XCTAssertTrue(session.hasWorked, "\(event) took it back")
        }
    }

    /// The phases a session reaches only once a turn has begun, written out.
    func testEveryPhaseSaysWhetherASessionInItHasWorked() {
        let working: Set<SessionPhase> = [
            .planning, .executing, .waitingForChildren, .waitingForUser, .completed, .failed,
        ]
        for phase in SessionPhase.allCases {
            XCTAssertEqual(phase.meansTheSessionHasWorked, working.contains(phase), "\(phase)")
        }
    }

    /// A memory file written before this was recorded still decodes, and says "not known to
    /// have worked" rather than failing the whole file.
    func testARememberedSessionFromBeforeThisFieldDecodes() throws {
        var session = testSession(phase: .idle, lastObservedAt: start)
        session.workedOnce = true
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        XCTAssertNotNil(object.removeValue(forKey: "workedOnce"), "the field is not where this test looks")

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertFalse(decoded.hasWorked)
    }

    // MARK: - Blocks

    func testEachSessionIsInTheBlockItsStateNames() {
        let expected: [(SessionPhase, SessionBlock)] = [
            (.planning, .active), (.executing, .active), (.waitingForChildren, .active),
            (.waitingForUser, .active), (.completed, .active), (.idle, .active),
            (.failed, .broken), (.disconnected, .broken), (.terminalClosed, .broken),
            (.sessionClosed, .closed),
        ]
        XCTAssertEqual(expected.count, SessionPhase.allCases.count, "a new phase needs a block")
        for (phase, block) in expected {
            let session = worked(testSession(phase: phase, lastObservedAt: start))
            XCTAssertEqual(SessionBlock.of(session, now: start), block, "\(phase)")
        }
    }

    /// A session opened a moment ago is not forgotten yet: it stays among the active until it
    /// has been silent as long as it takes for its `×` to start working.
    func testASessionThatNeverWorkedDropsDownWhenItsDismissButtonWakesUp() throws {
        let session = testSession(phase: .idle, lastObservedAt: start)
        let wakes = try XCTUnwrap(SessionPresence.dismissal(of: session, now: start).becomesDismissibleAt)

        XCTAssertEqual(SessionBlock.of(session, now: wakes - 1), .active)
        XCTAssertEqual(SessionBlock.of(session, now: wakes), .neverStarted)
        XCTAssertEqual(
            SessionBlock.of(worked(session), now: wakes + 3_600),
            .active,
            "a session that has worked is never counted as one that never started"
        )
    }

    /// Every block, once each, whatever the file said — a block left out would take its
    /// sessions out of the widget with it.
    func testAStoredBlockOrderAlwaysHoldsEveryBlockOnce() {
        XCTAssertEqual(
            SessionBlock.normalized(["closed", "sleeping", "closed", "active"]),
            [.closed, .active, .neverStarted, .broken]
        )
        XCTAssertEqual(SessionBlock.normalized([]), SessionBlock.defaultOrder)
    }

    // MARK: - Order

    func testArrivalKeepsTheOrderSessionsCameInAndSinksTheClosed() {
        var ordering = SessionOrdering()
        let sessions = [
            session(2, .executing), session(0, .sessionClosed), session(1, .idle),
        ]

        let ordered = ordering.order(sessions, mode: .arrival, blocks: SessionBlock.defaultOrder, now: start)

        XCTAssertEqual(ordered.map(\.arrivalIndex), [1, 2, 0])
    }

    func testRecentActivityPutsWhateverSpokeLastFirstAndSinksTheClosed() {
        var ordering = SessionOrdering()
        let sessions = [
            session(0, .idle, at: start + 1),
            session(1, .executing, at: start + 3),
            session(2, .sessionClosed, at: start + 9),
            session(3, .completed, at: start + 2),
        ]

        let ordered = ordering.order(sessions, mode: .recentActivity, blocks: SessionBlock.defaultOrder, now: start)

        XCTAssertEqual(ordered.map(\.arrivalIndex), [1, 3, 0, 2])
    }

    /// Groups in the icon's reading order, closed last, and in each group the session that
    /// joined it last comes first.
    func testAttentionGroupsSessionsAndPutsTheLatestToJoinAGroupFirst() {
        var ordering = SessionOrdering()
        var sessions = [session(0, .executing), session(1, .executing), session(2, .waitingForUser)]
        XCTAssertEqual(order(&ordering, sessions, .attention), [2, 1, 0], "the newer arrival is first")

        sessions[0] = session(0, .completed, at: start + 5)
        XCTAssertEqual(order(&ordering, sessions, .attention), [2, 1, 0])

        sessions[1] = session(1, .completed, at: start + 6)
        XCTAssertEqual(order(&ordering, sessions, .attention), [2, 1, 0], "1 finished after 0")

        sessions[0] = session(0, .executing, at: start + 7)
        sessions[0] = session(0, .completed, at: start + 8)
        XCTAssertEqual(
            order(&ordering, sessions, .attention),
            [2, 1, 0],
            "a group change the list never saw is no change"
        )
    }

    func testBlocksFollowTheChosenOrderAndPutTheLatestToJoinABlockFirst() {
        var ordering = SessionOrdering()
        var sessions = [
            worked(session(0, .completed)),
            worked(session(1, .executing)),
            worked(session(2, .sessionClosed)),
            worked(session(3, .failed)),
        ]
        let chosen: [SessionBlock] = [.broken, .active, .closed, .neverStarted]

        XCTAssertEqual(order(&ordering, sessions, .blocks, chosen), [3, 1, 0, 2])

        sessions[1] = worked(session(1, .disconnected, at: start + 5))
        XCTAssertEqual(order(&ordering, sessions, .blocks, chosen), [1, 3, 0, 2], "1 joined the broken last")
    }

    /// Moving a block moves where its sessions are shown, not when each joined it. Remembered
    /// by the block's place, every session would count as joining anew, and the order inside
    /// would fall back to their last events — here, the other way round.
    func testRearrangingTheBlocksKeepsTheOrderInsideEach() {
        var ordering = SessionOrdering()
        var sessions = [worked(session(0, .disconnected, at: start)), worked(session(1, .executing, at: start + 1))]
        _ = order(&ordering, sessions, .blocks)
        sessions[0] = worked(session(0, .executing, at: start + 5))
        XCTAssertEqual(order(&ordering, sessions, .blocks), [0, 1], "0 joined the active last")
        sessions[1] = worked(session(1, .completed, at: start + 10))
        XCTAssertEqual(order(&ordering, sessions, .blocks), [0, 1], "a change inside a block moves nothing")

        XCTAssertEqual(order(&ordering, sessions, .blocks, [.closed, .active, .broken, .neverStarted]), [0, 1])
    }

    /// The one change no event announces. It is noticed by the next ordering after the moment,
    /// and the session is placed as if it had joined the block at that moment.
    func testASessionDropsIntoNeverStartedByTimeAlone() throws {
        var ordering = SessionOrdering()
        let quiet = session(0, .idle)
        let busy = worked(session(1, .completed, at: start + 60))
        let wakes = try XCTUnwrap(SessionPresence.dismissal(of: quiet, now: start).becomesDismissibleAt)

        XCTAssertEqual(order(&ordering, [quiet, busy], .blocks, now: wakes - 1), [1, 0])
        XCTAssertEqual(
            ordering.order(
                [quiet, busy], mode: .blocks, blocks: [.neverStarted, .active, .broken, .closed], now: wakes
            )
            .map(\.arrivalIndex),
            [0, 1]
        )
    }

    /// Several sessions found in a new block by one ordering are placed by when each got there,
    /// not by where they happened to sit in the list handed over.
    func testSessionsThatJoinedABlockUnseenArePlacedByWhenTheyJoined() {
        var ordering = SessionOrdering()
        let sessions = [
            worked(session(0, .failed, at: start + 30)),
            worked(session(1, .failed, at: start + 10)),
            worked(session(2, .failed, at: start + 20)),
        ]

        XCTAssertEqual(order(&ordering, sessions, .blocks), [0, 2, 1])
    }

    /// A lost signal and a closed terminal are the app's findings, not the session's events:
    /// the reducer dates a lost signal at the last thing heard, and a closed terminal keeps its
    /// silence. Placed by that date, a session that has only just lost its signal sank below
    /// one that failed long before — the reverse of "the latest to join comes first". They
    /// joined when the list first saw them.
    func testAFindingJoinsItsBlockWhenTheListSeesItNotWhenTheSessionLastSpoke() {
        var ordering = SessionOrdering()
        let failed = worked(session(0, .failed, at: start + 20))
        let lost = worked(session(1, .disconnected, at: start + 10))
        let hung = worked(session(2, .terminalClosed, at: start + 5))

        XCTAssertEqual(order(&ordering, [failed, lost, hung], .blocks, now: start + 40).prefix(1), [2])
        XCTAssertEqual(
            order(&ordering, [failed, lost, hung], .blocks, now: start + 40),
            [2, 1, 0],
            "the two findings joined at the moment the list saw them, after the failure"
        )
    }

    func testOrderingTheSameSessionsAgainChangesNothing() {
        var ordering = SessionOrdering()
        let sessions = [worked(session(0, .completed)), worked(session(1, .executing)), session(2, .idle)]
        let first = order(&ordering, sessions, .blocks)

        XCTAssertEqual(order(&ordering, sessions, .blocks), first)
        XCTAssertEqual(order(&ordering, sessions.reversed(), .blocks), first, "the order handed over does not matter")
    }

    // MARK: - Holding places

    /// While the pointer is over the widget, rows keep the places they have. A new session
    /// goes to the end, where it moves nothing; one that is gone simply leaves.
    func testHoldingPlacesKeepsTheShownOrderAndAddsNewcomersAtTheEnd() {
        let ordered = [session(3, .idle), session(0, .idle), session(2, .idle)]

        let held = SessionOrdering.holdingPlaces(
            of: ["claude:session-2", "claude:session-1", "claude:session-0"],
            in: ordered
        )

        XCTAssertEqual(held.map(\.arrivalIndex), [2, 0, 3])
    }

    // MARK: - Helpers

    private func session(_ index: Int, _ phase: SessionPhase, at observed: Date? = nil) -> SessionSnapshot {
        testSession(index: index, phase: phase, lastObservedAt: observed ?? start + TimeInterval(index))
    }

    private func worked(_ snapshot: SessionSnapshot) -> SessionSnapshot {
        var worked = snapshot
        worked.workedOnce = true
        return worked
    }

    private func order(
        _ ordering: inout SessionOrdering,
        _ sessions: [SessionSnapshot],
        _ mode: SessionOrder,
        _ blocks: [SessionBlock] = SessionBlock.defaultOrder,
        now: Date? = nil
    ) -> [Int] {
        ordering.order(sessions, mode: mode, blocks: blocks, now: now ?? start).map(\.arrivalIndex)
    }
}
