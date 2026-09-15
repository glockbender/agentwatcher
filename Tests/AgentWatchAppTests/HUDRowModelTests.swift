import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// What one row is asked to draw, decided before any view exists.
///
/// The model is what tells a rebuild from a redraw: two models that compare equal mean the
/// row on screen is already right and must not be touched. Everything that depends on the
/// clock is therefore reduced to the thresholds that are actually visible — a row does not
/// change because a second passed, it changes when it crosses into being dismissible.
@MainActor
final class HUDRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// The property the whole diff rests on: a session nobody touched produces the same model
    /// a minute later, so its row survives an event that belonged to somebody else.
    func testASessionNobodyTouchedKeepsItsModelAsTimePasses() {
        let session = testSession(phase: .executing, lastObservedAt: now)

        XCTAssertEqual(
            HUDRowModel(snapshot: session, now: now, layout: .standard),
            HUDRowModel(snapshot: session, now: now.addingTimeInterval(60), layout: .standard)
        )
    }

    /// And the exception that makes the rule safe: crossing the silence threshold *is* a
    /// change, because it puts a dismiss button in the row. Measured before the diff existed:
    /// the row used to gain that button from any other session's event.
    func testCrossingTheSilenceThresholdChangesTheModel() {
        let waiting = testSession(phase: .waitingForUser, lastObservedAt: now)
        let justBeforeTheThreshold = now.addingTimeInterval(
            SessionFreshnessEvaluator.defaultDisconnectAfter - 1)
        let atTheThreshold = now.addingTimeInterval(SessionFreshnessEvaluator.defaultDisconnectAfter)

        XCTAssertEqual(
            HUDRowModel(snapshot: waiting, now: justBeforeTheThreshold, layout: .standard).dismissal,
            .notOffered(until: now + SessionFreshnessEvaluator.defaultDisconnectAfter))
        XCTAssertEqual(
            HUDRowModel(snapshot: waiting, now: atTheThreshold, layout: .standard).dismissal, .now)
    }

    /// Changing the template changes what every row draws, so it has to change every row's
    /// model — otherwise the list keeps the rows it already has, and the setting appears not
    /// to work until each session speaks again. The two templates below produce the same name
    /// and the same dismissal, which is exactly the case a model carrying only those misses.
    func testAChangedTemplateChangesEveryRowsModel() {
        let session = testSession(title: "Переписать ingress", lastObservedAt: now)

        XCTAssertNotEqual(
            HUDRowModel(snapshot: session, now: now, layout: .standard),
            HUDRowModel(snapshot: session, now: now, layout: RowLayout(parts: [.lamp, .name, .gap, .branch]))
        )
    }

    /// The row is measured without the part that gives way and that part is put back
    /// afterwards, so the model has to carry its text — which is the name only as long as the
    /// name is the part that gives way.
    func testTheModelCarriesTheTextOfThePartThatGivesWay() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.gitBranch = "feature/probe"
        let branchGivesWay = RowLayout(parts: [.timer, .name, .branch, .gap], flexible: .branch)

        XCTAssertEqual(
            HUDRowModel(snapshot: session, now: now, layout: branchGivesWay).flexibleText,
            "feature/probe"
        )
        XCTAssertEqual(
            HUDRowModel(snapshot: session, now: now, layout: .standard).flexibleText,
            "Fix the row"
        )
    }

    /// `Name only` says what it does, and the model is where that shows up: the part that
    /// gives way has nothing to say, so the row is left a lamp and a clock. That is the
    /// person's choice to make — see ADR-0011.
    func testNameOnlyLeavesANamelessSessionWithoutOne() {
        let nameless = testSession(title: nil, projectName: "agent-watch", lastObservedAt: now)
        let titleOnly = RowLayout(parts: RowLayout.standard.parts, nameStyle: .title)

        XCTAssertNil(HUDRowModel(snapshot: nameless, now: now, layout: titleOnly).flexibleText)
        XCTAssertEqual(
            HUDRowModel(snapshot: nameless, now: now, layout: .standard).flexibleText,
            "[still no name] in agent-watch"
        )
    }
}
