import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// An event belongs to one session, and only that session's row may be rebuilt for it.
///
/// This is what the diff is for, and it is worth measuring rather than trusting: a rebuilt
/// row is a new view, so it loses the pointer that was resting on it, the highlight that
/// went with it, and the tooltip that was about to appear. Rebuilding all of them for every
/// event is what made those three need rescuing by hand.
@MainActor
final class HUDRowReuseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAnEventAboutOneSessionLeavesEveryOtherRowUntouched() throws {
        let controller = try makeController()
        let quiet = testSession(index: 0, title: "тихая", phase: .idle, lastObservedAt: now)
        let busy = testSession(index: 1, title: "шумная", phase: .idle, lastObservedAt: now)
        controller.render(WidgetState(sessions: [quiet, busy]))
        let quietRow = try XCTUnwrap(controller.currentRow(for: quiet.id))
        let busyRow = try XCTUnwrap(controller.currentRow(for: busy.id))

        let busyWorking = testSession(
            index: 1, title: "шумная", phase: .executing, lastObservedAt: now.addingTimeInterval(1))
        controller.render(WidgetState(sessions: [quiet, busyWorking]))

        XCTAssertTrue(
            controller.currentRow(for: quiet.id) === quietRow,
            "the row nothing happened to was rebuilt anyway"
        )
        XCTAssertFalse(
            controller.currentRow(for: busy.id) === busyRow,
            "the row that changed has to be rebuilt to show it"
        )
    }

    /// The one the clock changes rather than an event: after half an hour of silence a row
    /// gains its `×`. Before the diff it arrived on any other session's event; it has to keep
    /// arriving now that other sessions no longer touch it.
    func testASilentRowGainsItsDismissButtonOnSomebodyElsesEvent() throws {
        let controller = try makeController()
        let waiting = testSession(
            index: 0,
            title: "ждёт человека",
            phase: .waitingForUser,
            lastObservedAt: now.addingTimeInterval(-SessionFreshnessEvaluator.defaultDisconnectAfter - 60)
        )
        let busy = testSession(index: 1, title: "шумная", phase: .idle, lastObservedAt: .now)
        controller.render(WidgetState(sessions: [waiting, busy]))

        XCTAssertTrue(
            hasDismissButton(try XCTUnwrap(controller.currentRow(for: waiting.id))),
            "a session silent for longer than the threshold has to offer a way out"
        )
    }

    /// A closed session sinks below the live ones. Neither row draws anything new, so both
    /// views are kept and only their places change.
    func testAReorderMovesTheRowsItAlreadyBuilt() throws {
        let controller = try makeController()
        let first = testSession(index: 0, title: "первая", phase: .executing, lastObservedAt: now)
        let second = testSession(index: 1, title: "вторая", phase: .executing, lastObservedAt: now)
        controller.render(WidgetState(sessions: [first, second]))
        let firstRow = try XCTUnwrap(controller.currentRow(for: first.id))

        var closed = first
        closed.phase = .sessionClosed
        controller.render(WidgetState(sessions: [closed, second]))

        XCTAssertEqual(
            rowOrder(of: controller), [second.id, closed.id],
            "a closed session belongs below the live ones"
        )
        XCTAssertFalse(
            controller.currentRow(for: second.id) === firstRow,
            "the rows must not be confused with one another"
        )
    }

    /// A rebuilt row prints its own elapsed time, and it has to print it from the moment the
    /// event arrived rather than from whenever the list happened to be built.
    ///
    /// Before the diff this could not go wrong: every event built a whole new list, so every
    /// row was born with a fresh clock. Now a list can live for hours, and the per-second tick
    /// that would cover the mistake stops as soon as no session claims work — `waiting for
    /// user` is exactly that case, and exactly where a wrong age is read as "nobody is
    /// waiting for me".
    func testARebuiltRowShowsTheAgeAtTheMomentTheEventArrived() throws {
        let built = Date(timeIntervalSince1970: 1_000_000)
        let session = testSession(index: 0, title: "сессия", phase: .executing, lastObservedAt: built)
        let list = HUDSessionListView(
            models: rowModels([session], now: built),
            usageLimits: [],
            now: built,
            availableWidth: 400,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )

        // Forty minutes later the session stops working and waits for a person. Its row is
        // rebuilt, and nothing ticks afterwards.
        let later = built.addingTimeInterval(2_400)
        var waiting = session
        waiting.phase = .waitingForUser
        waiting.lastObservedAt = later
        list.apply(models: rowModels([waiting], now: later), now: later)

        let row = try XCTUnwrap(list.row(for: session.id))
        XCTAssertEqual(
            row.arrangedSubviews.compactMap { $0 as? NSTextField }.first?.stringValue,
            "0s",
            "the event had just arrived, so the row cannot claim it is forty minutes old"
        )
    }

    private func rowOrder(of controller: HUDPanelController) -> [String] {
        controller.visibleRows.map(\.snapshot.id)
    }

    private func hasDismissButton(_ view: NSView) -> Bool {
        if let button = view as? RowActionButton, button.rowAction == .dismiss {
            return true
        }
        return view.subviews.contains { hasDismissButton($0) }
    }

    private func makeController() throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let controller = HUDPanelController(
            locator: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences)
        )
        controller.showWindow(nil)
        return controller
    }
}
