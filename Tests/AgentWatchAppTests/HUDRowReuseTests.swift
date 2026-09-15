import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// An event belongs to one session, and only that session's row may be rebuilt for it.
///
/// This is what the diff is for, and it is worth measuring rather than trusting: a rebuilt
/// row is a new view, so it loses the pointer that was resting on it, the highlight that
/// went with it, and the hover card that was about to open. Rebuilding all of them for every
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
            lastObservedAt: now.addingTimeInterval(-SessionFreshnessEvaluator.defaultDisconnectAfter + 120)
        )
        let busy = testSession(index: 1, title: "шумная", phase: .idle, lastObservedAt: now)
        controller.clock = { self.now }
        controller.render(WidgetState(sessions: [waiting, busy]))
        XCTAssertFalse(
            hasDismissButton(try XCTUnwrap(controller.currentRow(for: waiting.id))),
            "two minutes short of the threshold there is nothing to dismiss yet"
        )

        // Three minutes later the other session says something. The waiting one has crossed
        // the threshold in the meantime, without an event of its own.
        controller.clock = { self.now.addingTimeInterval(180) }
        var busyLater = busy
        busyLater.phase = .executing
        busyLater.lastObservedAt = now.addingTimeInterval(180)
        controller.render(WidgetState(sessions: [waiting, busyLater]))

        XCTAssertTrue(
            hasDismissButton(try XCTUnwrap(controller.currentRow(for: waiting.id))),
            "a session silent for longer than the threshold has to offer a way out"
        )
    }

    /// A closed session sinks below the live ones. The closed row is rebuilt — it draws a
    /// different lamp — and the other draws nothing new, so its view is kept and only moved.
    func testAReorderMovesTheRowsItAlreadyBuilt() throws {
        let controller = try makeController()
        let first = testSession(index: 0, title: "первая", phase: .executing, lastObservedAt: now)
        let second = testSession(index: 1, title: "вторая", phase: .executing, lastObservedAt: now)
        controller.render(WidgetState(sessions: [first, second]))
        let firstRow = try XCTUnwrap(controller.currentRow(for: first.id))
        let secondRow = try XCTUnwrap(controller.currentRow(for: second.id))

        var closed = first
        closed.phase = .sessionClosed
        controller.render(WidgetState(sessions: [closed, second]))

        XCTAssertEqual(
            rowOrder(of: controller), [second.id, closed.id],
            "a closed session belongs below the live ones"
        )
        XCTAssertTrue(
            controller.currentRow(for: second.id) === secondRow,
            "the row nothing happened to is kept, in its new place"
        )
        XCTAssertFalse(
            controller.currentRow(for: closed.id) === firstRow,
            "the row that closed has to be rebuilt to show it"
        )
    }

    /// Two equal models in a new order: neither row draws anything new, so both views are
    /// kept and only their places change. `insertArrangedSubview` moves a view that is
    /// already arranged, and this is the test that says so.
    func testAPureReorderKeepsBothRowsAndMovesThem() throws {
        let first = testSession(index: 0, title: "первая", phase: .executing, lastObservedAt: now)
        let second = testSession(index: 1, title: "вторая", phase: .executing, lastObservedAt: now)
        let list = makeList([first, second], now: now)
        let firstRow = try XCTUnwrap(list.row(for: first.id))
        let secondRow = try XCTUnwrap(list.row(for: second.id))

        // Built by hand: `rowModels` orders for display, which would undo the reorder.
        let reversed = [second, first].map { HUDRowModel(snapshot: $0, now: now, layout: .standard) }
        XCTAssertTrue(list.apply(models: reversed, now: now), "a new order is a change")

        XCTAssertTrue(list.row(for: first.id) === firstRow)
        XCTAssertTrue(list.row(for: second.id) === secondRow)
        XCTAssertEqual(list.rows.map(\.snapshot.id), [second.id, first.id])
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
        let list = makeList([session], now: built)

        // Forty minutes later the session stops working and waits for a person. Its row is
        // rebuilt, and nothing ticks afterwards.
        let later = built.addingTimeInterval(2_400)
        var waiting = session
        waiting.phase = .waitingForUser
        waiting.lastObservedAt = later
        list.apply(models: rowModels([waiting], now: later), now: later)

        XCTAssertEqual(
            timerText(of: try XCTUnwrap(list.row(for: session.id))),
            "0s",
            "the event had just arrived, so the row cannot claim it is forty minutes old"
        )
    }

    /// The other half of the same hazard: a row the diff keeps. Its age was right when it was
    /// built, and the tick that would keep it right stops as soon as no session claims work —
    /// two sessions waiting for a person is exactly that state. Before the diff every event
    /// rebuilt every row at the moment it arrived; a kept row has to restate its age at that
    /// same moment, or it says "12s" while a person has been waited for since the morning.
    func testARowTheDiffKeepsRestatesItsAgeAtTheMomentTheEventArrived() throws {
        let built = Date(timeIntervalSince1970: 1_000_000)
        let waiting = testSession(index: 0, title: "ждёт", phase: .waitingForUser, lastObservedAt: built)
        let other = testSession(index: 1, title: "другая", phase: .waitingForUser, lastObservedAt: built)
        let list = makeList([waiting, other], now: built)
        let waitingRow = try XCTUnwrap(list.row(for: waiting.id))

        // Twenty minutes: long enough to read differently, short of the half hour at which the
        // row would gain its `×` and be rebuilt for that reason instead.
        let later = built.addingTimeInterval(1_200)
        var closed = other
        closed.phase = .sessionClosed
        closed.lastObservedAt = later
        list.apply(models: rowModels([waiting, closed], now: later), now: later)

        XCTAssertTrue(list.row(for: waiting.id) === waitingRow, "nothing about this row changed, so it is kept")
        XCTAssertEqual(
            timerText(of: waitingRow),
            "20m",
            "nothing ticks while nobody works, so the kept row has to be told the time by the event"
        )
    }

    /// A list reached by the diff has to look exactly like one built whole from the same
    /// models — byte for byte, drawn offscreen. This is the one check that catches whatever a
    /// kept row failed to restate, whichever attribute it turns out to be.
    func testAListReachedByTheDiffDrawsLikeOneBuiltWhole() throws {
        let sessions = (0..<4).map { index in
            testSession(index: index, title: "Сессия \(index)", phase: .executing, lastObservedAt: now)
        }
        let later = now.addingTimeInterval(90)
        let whole = makeList(sessions, now: later)
        let grown = makeList(Array(sessions.dropLast()), now: now)
        grown.apply(models: rowModels(sessions, now: later), now: later)

        XCTAssertEqual(try bitmap(of: whole), try bitmap(of: grown))
    }

    func testSilentRowGainsDismissAtItsDeadlineWithoutAnUnrelatedEvent() throws {
        let controller = try makeController()
        defer { controller.shutdown() }
        let waiting = testSession(index: 0, phase: .waitingForUser, lastObservedAt: now)
        controller.clock = { self.now }
        controller.render(WidgetState(sessions: [waiting]))
        controller.show()
        XCTAssertEqual(controller.nextDismissRefreshAt, now + SessionFreshnessEvaluator.defaultDisconnectAfter)
        XCTAssertFalse(hasDismissButton(try XCTUnwrap(controller.currentRow(for: waiting.id))))
        let later = now + SessionFreshnessEvaluator.defaultDisconnectAfter
        controller.clock = { later }
        controller.refreshTimers(now: later)
        XCTAssertTrue(hasDismissButton(try XCTUnwrap(controller.currentRow(for: waiting.id))))
        XCTAssertNil(controller.nextDismissRefreshAt, "the deadline is spent; an idle row needs no further wakeups")
    }

    func testNewEvidenceMovesDismissalDeadlineAndHidingCancelsIt() throws {
        let controller = try makeController()
        defer { controller.shutdown() }
        var waiting = testSession(index: 0, phase: .waitingForUser, lastObservedAt: now)
        controller.clock = { self.now }
        controller.render(WidgetState(sessions: [waiting]))
        controller.show()
        waiting.lastObservedAt = now + 60
        controller.render(WidgetState(sessions: [waiting]))
        XCTAssertEqual(controller.nextDismissRefreshAt, now + 60 + SessionFreshnessEvaluator.defaultDisconnectAfter)
        controller.toggle()
        XCTAssertNil(controller.nextDismissRefreshAt)
    }

    private func rowOrder(of controller: HUDPanelController) -> [String] {
        controller.visibleRows.map(\.snapshot.id)
    }

    private func makeList(_ sessions: [SessionSnapshot], now: Date) -> HUDSessionListView {
        HUDSessionListView(
            models: rowModels(sessions, now: now),
            usageLimits: [],
            now: now,
            availableWidth: 400,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
    }

    private func timerText(of row: HUDSessionRowView) -> String? {
        row.arrangedSubviews.compactMap { $0 as? NSTextField }.first?.stringValue
    }

    /// The list drawn into a bitmap by `cacheDisplay`, inside a window because a view outside
    /// one lays out against nothing. No screen is involved.
    private func bitmap(of list: HUDSessionListView) throws -> Data {
        let size = NSSize(width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(list.bitmapImageRepForCachingDisplay(in: list.bounds))
        list.cacheDisplay(in: list.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func hasDismissButton(_ view: NSView) -> Bool {
        if view is RowDismissButton {
            return true
        }
        return view.subviews.contains { hasDismissButton($0) }
    }

    private func makeController() throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.showWindow(nil)
        return controller
    }
}
