import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// Where the hover card lands. A widget lives parked in a corner, so the interesting cases
/// are all edges — and they are worth checking without a second display to hand.
@MainActor
final class SessionHoverCardTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let size = NSSize(width: 340, height: 80)

    func testTheCardSitsJustUnderTheRowItExplains() {
        let row = NSRect(x: 500, y: 500, width: 360, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: screen)

        XCTAssertEqual(origin.x, 500)
        XCTAssertEqual(origin.y, 500 - size.height - SessionHoverCard.rowGap)
    }

    /// A widget at the bottom of the screen has no room underneath, and a card drawn there
    /// would be half off the display.
    func testACardWithNoRoomBelowGoesAboveTheRow() {
        let row = NSRect(x: 100, y: 20, width: 360, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: screen)

        XCTAssertEqual(origin.y, row.maxY + SessionHoverCard.rowGap)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
    }

    func testACardIsPulledBackInsideTheRightEdge() {
        let row = NSRect(x: 1_300, y: 500, width: 130, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: screen)

        XCTAssertEqual(origin.x, screen.maxX - size.width)
        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX)
    }

    func testACardIsPulledBackInsideTheLeftEdge() {
        let row = NSRect(x: -60, y: 500, width: 360, height: 20)

        XCTAssertEqual(SessionHoverCard.origin(below: row, size: size, visibleFrame: screen).x, screen.minX)
    }

    /// A menu bar or a dock takes a bite out of the visible area, and the card belongs
    /// inside what is left rather than inside the display.
    func testTheCardStaysInsideTheUsableAreaRatherThanTheDisplay() {
        let usable = NSRect(x: 0, y: 80, width: 1_440, height: 780)
        let row = NSRect(x: 100, y: 120, width: 360, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: usable)

        XCTAssertGreaterThanOrEqual(origin.y, usable.minY)
        XCTAssertLessThanOrEqual(origin.y + size.height, usable.maxY)
    }

    /// A card taller than the space it is given must not be positioned by a negative width:
    /// clamping the wrong way round would put it further out than where it started.
    func testACardLargerThanTheScreenIsStillPlacedInsideIt() {
        let tiny = NSRect(x: 0, y: 0, width: 200, height: 60)
        let row = NSRect(x: 10, y: 20, width: 180, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: tiny)

        XCTAssertGreaterThanOrEqual(origin.x, tiny.minX)
        XCTAssertGreaterThanOrEqual(origin.y, tiny.minY)
    }

    /// With no screen to ask — an unplugged display between two events — the card still
    /// answers with the place it wanted, rather than refusing to appear.
    func testWithNoKnownScreenTheCardKeepsItsIntendedPlace() {
        let row = NSRect(x: 500, y: 500, width: 360, height: 20)

        let origin = SessionHoverCard.origin(below: row, size: size, visibleFrame: nil)

        XCTAssertEqual(origin, NSPoint(x: 500, y: 500 - size.height - SessionHoverCard.rowGap))
    }
}

/// The card is opened by the pointer and then left standing while the session it describes
/// goes quiet. What it says has to keep up with the row underneath it.
@MainActor
final class HoverCardFreshnessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    /// The card carries "Last event Ns ago", the same age the row's timer prints. It was
    /// refreshed only when an event rebuilt the list, so above a quiet session it stood at
    /// whatever it had said minutes earlier while the row beside it counted on.
    func testTheOpenCardAgesWithTheRowItDescribes() throws {
        let controller = try makeController()
        var session = SessionSnapshot(
            id: "claude:alpha",
            source: .claude,
            arrivalIndex: 0,
            title: "Сессия",
            phase: .executing,
            lastObservedAt: start
        )
        session.contextTelemetry = nil
        controller.show()
        controller.render(WidgetState(sessions: [session]))

        let row = try XCTUnwrap(controller.currentRow(for: session.id))
        controller.hoverChanged(row, isInside: true)
        controller.showHoverCard(for: session.id)

        let opened = try XCTUnwrap(controller.visibleHoverCardText)
        XCTAssertTrue(opened.contains("Last event"), opened)

        controller.refreshTimers(now: start.addingTimeInterval(45))
        let aged = try XCTUnwrap(controller.visibleHoverCardText)

        XCTAssertNotEqual(aged, opened, "the card kept saying what it said when it opened")
        XCTAssertTrue(aged.contains("Last event 45s ago"), aged)
        controller.shutdown()
    }

    private func makeController() throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        return HUDPanelController(
            locator: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: HUDFrameStore(preferences: preferences),
            settings: WidgetSettingsStore(preferences: preferences)
        )
    }
}

/// When the card appears, stays and closes — checked directly, without a window.
///
/// Every case here was a real defect or is one step away from one. The rule used to live
/// inside the panel controller, where reaching it meant building a widget and where the
/// half-second countdown could not be advanced, so the two bugs below were found by using the
/// app rather than by running the tests.
@MainActor
final class HoverCardStateTests: XCTestCase {
    /// The bug this type exists to keep fixed. The list is rebuilt on every event, which hands
    /// the pointer a new view for the same session; that view reports an arrival although the
    /// pointer never moved. Re-arming on it restarted the countdown every couple of seconds,
    /// so on a busy session — the one most worth inspecting — the card never appeared.
    func testARebuiltRowUnderARestingPointerDoesNotRestartTheCountdown() {
        var hover = HoverCardState()
        XCTAssertEqual(hover.pointerEntered(sessionID: "a"), .arm(sessionID: "a"))

        XCTAssertEqual(hover.pointerEntered(sessionID: "a"), .none)
    }

    func testMovingToAnotherRowStartsThatRowsCountdown() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")

        XCTAssertEqual(hover.pointerEntered(sessionID: "b"), .arm(sessionID: "b"))
    }

    /// A row being replaced reports its own exit on the way out. Acting on that would close
    /// the card under a pointer that had already moved to the next row.
    func testARowLeftBehindCannotCloseSomebodyElsesCard() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")
        _ = hover.pointerEntered(sessionID: "b")

        XCTAssertEqual(hover.pointerLeft(sessionID: "a"), .none)
        XCTAssertEqual(hover.hoveredSessionID, "b")
    }

    func testLeavingTheRowThePointerIsOnClosesTheCard() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")

        XCTAssertEqual(hover.pointerLeft(sessionID: "a"), .dismiss)
        XCTAssertNil(hover.hoveredSessionID)
    }

    func testLeavingTheWidgetClosesTheCard() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")

        XCTAssertEqual(hover.pointerLeftWidget(), .dismiss)
    }

    /// The widget reports the pointer leaving whether or not it was on a row, and closing a
    /// card nobody opened is a window call for nothing.
    func testLeavingAWidgetNoRowWasHoveredOnAsksForNothing() {
        var hover = HoverCardState()

        XCTAssertEqual(hover.pointerLeftWidget(), .none)
    }

    /// Half a second is long enough for the pointer to be somewhere else entirely.
    func testTheCountdownOnlyShowsTheSessionThePointerIsStillOn() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")
        _ = hover.pointerEntered(sessionID: "b")

        XCTAssertEqual(hover.countdownFinished(for: "a"), .none)
        XCTAssertEqual(hover.countdownFinished(for: "b"), .present(sessionID: "b"))
    }

    /// A rebuild leaves the card where it is. What it needs is the row's highlight put back —
    /// the replacement row gets no arrival of its own if the pointer has not moved.
    func testARebuildLeavesAnOpenCardAloneAndReattachesItsRow() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")

        XCTAssertEqual(hover.sessionsChanged(to: ["a", "b"]), .reattach(sessionID: "a"))
        XCTAssertEqual(hover.hoveredSessionID, "a")
    }

    /// The other bug: a card describing a session that is no longer in the list.
    func testACardClosesWhenItsSessionLeavesTheList() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")

        XCTAssertEqual(hover.sessionsChanged(to: ["b"]), .dismiss)
        XCTAssertNil(hover.hoveredSessionID)
    }

    /// The commonest situation of all: sessions change twice a second and the pointer is
    /// nowhere near the widget.
    func testAListChangeWithThePointerElsewhereAsksForNothing() {
        var hover = HoverCardState()

        XCTAssertEqual(hover.sessionsChanged(to: ["a"]), .none)
    }

    /// The countdown outlives the pointer by up to half a second, and a timer cannot be
    /// un-fired. Whatever cancelling the controller does, the answer here has to be the same:
    /// a card must never appear over a widget the pointer has already left.
    func testACountdownThatOutlivesThePointerShowsNothing() {
        var hover = HoverCardState()
        _ = hover.pointerEntered(sessionID: "a")
        _ = hover.pointerLeftWidget()

        XCTAssertEqual(hover.countdownFinished(for: "a"), .none)
    }
}
