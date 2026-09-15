import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// What has to happen to the list of rows so it shows the new models — decided over the
/// models alone, with no view anywhere near it.
///
/// The point of stating it this way is that the answer for an ordinary event is "rebuild one
/// row". The widget used to rebuild all of them for every event, which is why the row under
/// the pointer, the scroll position and the tooltip each needed rescuing by hand.
@MainActor
final class RowListUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAnEventAboutOneSessionRebuildsOnlyThatRow() {
        let quiet = model(index: 0, title: "тихая")
        let busy = model(index: 1, title: "шумная", phase: .idle)
        let busyWorking = model(index: 1, title: "шумная", phase: .executing)

        let update = rowListUpdate(from: [quiet, busy], to: [quiet, busyWorking])

        XCTAssertEqual(update.rebuilt, [busy.id])
        XCTAssertEqual(update.inserted, [])
        XCTAssertEqual(update.removed, [])
    }

    func testASessionThatLeftIsRemovedAndOneThatArrivedIsInserted() {
        let staying = model(index: 0, title: "остаётся")
        let leaving = model(index: 1, title: "уходит")
        let arriving = model(index: 2, title: "приходит")

        let update = rowListUpdate(from: [staying, leaving], to: [staying, arriving])

        XCTAssertEqual(update.removed, [leaving.id])
        XCTAssertEqual(update.inserted, [arriving.id])
        XCTAssertEqual(update.rebuilt, [])
    }

    /// A closed session sinks below the live ones. Nothing about either row changed, so both
    /// views are kept and only their places swap.
    func testAReorderKeepsEveryRowAndStatesTheNewOrder() {
        let first = model(index: 0, title: "первая")
        let second = model(index: 1, title: "вторая")

        let update = rowListUpdate(from: [first, second], to: [second, first])

        XCTAssertEqual(update.rebuilt, [])
        XCTAssertEqual(update.order, [second.id, first.id])
    }

    /// The quiet row's `×` arrives from the clock, not from an event of its own. Before the
    /// diff every event rebuilt every row, so it appeared on somebody else's event; the diff
    /// has to notice it by itself or the button would wait for a session that never speaks.
    func testARowThatBecameDismissibleIsRebuiltWithoutAnEventOfItsOwn() {
        let waiting = testSession(index: 0, phase: .waitingForUser, lastObservedAt: now)
        let before = HUDRowModel(snapshot: waiting, now: now, layout: .standard)
        let after = HUDRowModel(
            snapshot: waiting,
            now: now.addingTimeInterval(SessionFreshnessEvaluator.defaultDisconnectAfter),
            layout: .standard
        )

        XCTAssertEqual(rowListUpdate(from: [before], to: [after]).rebuilt, [before.id])
    }

    /// The commonest answer of all: the sweep ran, nothing moved, and the list must be left
    /// alone. Asked of the update itself so no caller has to work it out from four fields.
    func testAnIdenticalReportChangesNothing() {
        let models = [model(index: 0, title: "первая"), model(index: 1, title: "вторая")]

        XCTAssertTrue(rowListUpdate(from: models, to: models).changesNothing)
    }

    func testAReorderIsAChange() {
        let first = model(index: 0, title: "первая")
        let second = model(index: 1, title: "вторая")

        XCTAssertFalse(rowListUpdate(from: [first, second], to: [second, first]).changesNothing)
    }

    private func model(index: Int, title: String, phase: SessionPhase = .idle) -> HUDRowModel {
        HUDRowModel(
            snapshot: testSession(index: index, title: title, phase: phase, lastObservedAt: now),
            now: now,
            layout: .standard
        )
    }
}
