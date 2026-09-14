import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// The width breakpoints that decide how much of a session's own name a row shows.
@MainActor
final class WidgetLayoutTests: XCTestCase {
    private let minimumTitleWidth: CGFloat = 52

    func testAWideRowShowsTheWholeName() {
        XCTAssertEqual(display(availableWidth: 300, fullTitleWidth: 240), .fullName)
    }

    func testTheFullNameWinsAtExactlyItsOwnWidth() {
        XCTAssertEqual(display(availableWidth: 240, fullTitleWidth: 240), .fullName)
    }

    /// The bug this guards: a shortened name only shortens against a width it was given.
    /// Without one the label kept its natural size, the row grew past the widget, and the
    /// name never truncated at all.
    func testANarrowerRowCapsTheNameAtWhatIsLeft() {
        XCTAssertEqual(display(availableWidth: 150, fullTitleWidth: 240), .truncated(toWidth: 150))
    }

    func testTheShortenedNameStillNeedsRoomToBeWorthShowing() {
        XCTAssertEqual(display(availableWidth: 51, fullTitleWidth: 240), .initial)
        XCTAssertEqual(display(availableWidth: 52, fullTitleWidth: 240), .truncated(toWidth: 52))
    }

    /// Even with no room at all the row keeps a first letter: it is something to hover, and
    /// it tells two neighbouring rows apart, which an empty space does not.
    func testNoRoomAtAllStillLeavesAFirstLetter() {
        XCTAssertEqual(display(availableWidth: -50, fullTitleWidth: 240), .initial)
    }

    func testASessionWithoutANameNeverClaimsSpaceForOne() {
        XCTAssertEqual(display(availableWidth: 500, fullTitleWidth: 0), .hidden)
    }

    // MARK: - Row furniture

    /// Everything that is not the name takes room, and the budget has to see all of it.
    func testTheFurnitureBudgetGrowsWithWhatTheRowActuallyCarries() {
        var quiet = snapshot()
        quiet.clientKind = nil
        var busy = snapshot()
        busy.clientKind = .cli

        busy.activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: quiet.lastObservedAt)
        ]

        let now = quiet.lastObservedAt
        let quietWidth = nameless(quiet, now: now).furnitureWidth
        let busyWidth = nameless(busy, now: now).furnitureWidth

        XCTAssertGreaterThan(
            quietWidth,
            HUDSessionRowView.timerWidth + SessionLampView.diameter,
            "the source icon and the gaps between the parts are in every row too"
        )
        XCTAssertGreaterThan(busyWidth, quietWidth, "a client icon and a counter both take room")
    }

    // MARK: - Row order

    func testLiveSessionsKeepTheOrderTheyArrivedIn() {
        let sessions = [session(arrivalIndex: 2), session(arrivalIndex: 0), session(arrivalIndex: 1)]

        XCTAssertEqual(orderedForDisplay(sessions).map(\.arrivalIndex), [0, 1, 2])
    }

    /// The complaint this answers: sorting by the most recent event kept lifting whichever
    /// session had just spoken to the top, so rows moved under the pointer.
    func testTheMostRecentEventDoesNotChangeTheOrder() {
        var older = session(arrivalIndex: 0)
        older.lastObservedAt = Date(timeIntervalSince1970: 0)
        var newer = session(arrivalIndex: 1)
        newer.lastObservedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(orderedForDisplay([older, newer]).map(\.arrivalIndex), [0, 1])
        XCTAssertEqual(orderedForDisplay([newer, older]).map(\.arrivalIndex), [0, 1])
    }

    func testClosedSessionsSinkBelowTheLiveOnesAndKeepTheirOwnOrder() {
        var firstClosed = session(arrivalIndex: 0)
        firstClosed.phase = .sessionClosed
        var secondClosed = session(arrivalIndex: 1)
        secondClosed.phase = .sessionClosed
        let live = session(arrivalIndex: 2)

        XCTAssertEqual(
            orderedForDisplay([firstClosed, secondClosed, live]).map(\.arrivalIndex),
            [2, 0, 1]
        )
    }

    /// `no signal` is reversible: one event brings the session back. Sinking it would move
    /// the row twice for a state that may not last a minute.
    func testADisconnectedSessionStaysWhereItIs() {
        var disconnected = session(arrivalIndex: 0)
        disconnected.phase = .disconnected

        XCTAssertEqual(orderedForDisplay([session(arrivalIndex: 1), disconnected]).map(\.arrivalIndex), [0, 1])
    }

    private func display(availableWidth: CGFloat, fullTitleWidth: CGFloat) -> SessionTitleDisplay {
        chooseTitleDisplay(
            availableWidth: availableWidth,
            fullTitleWidth: fullTitleWidth,
            minimumTitleWidth: minimumTitleWidth
        )
    }

    /// A row before it is given a name — the state its furniture width is measured in.
    private func nameless(_ snapshot: SessionSnapshot, now: Date) -> HUDSessionRowView {
        HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            onFocus: {},
            onRemove: SessionPresence.isDismissible(snapshot, now: now) ? {} : nil
        )
    }

    private func session(arrivalIndex: Int) -> SessionSnapshot {
        testSession(index: arrivalIndex, lastObservedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func snapshot() -> SessionSnapshot {
        session(arrivalIndex: 0)
    }
}
