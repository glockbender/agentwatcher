import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The row drawn from a template rather than from a list in the source file.
///
/// Asked of the row itself: `drawnParts` is what the row put on screen, in order, which is
/// also what the row needs in order to insert the part that gives way at the right place.
@MainActor
final class RowTemplateDrawingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testTheRowDrawsThePartsInTheOrderTheTemplateGives() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.contextTelemetry = .init(totalInputTokens: 85_000)

        let row = makeRow(session, layout: RowLayout(parts: [.context, .lamp, .gap, .timer]))

        XCTAssertEqual(row.drawnParts, [.context, .lamp, .gap, .timer])
    }

    /// A template names the parts a person wants; what the session has is a separate question.
    /// The marker is the clearest case — most rows have no fault to draw — and a row that kept
    /// an empty box for it would spend width on the absence of news.
    func testAPartTheSessionCannotFillIsLeftOut() {
        let healthy = testSession(title: "Fix the row", lastObservedAt: now)

        let row = makeRow(healthy, layout: RowLayout(parts: [.timer, .fault, .lamp, .gap]))

        XCTAssertEqual(row.drawnParts, [.timer, .lamp, .gap])
    }

    /// The part that gives way is left out while the row is measured and put back afterwards,
    /// so it has to go back where the template put it — not at the gap, which is where the
    /// name went when the name was the only part that could give way.
    func testThePartThatGivesWayGoesBackWhereTheTemplatePutsIt() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.gitBranch = "feature/probe"
        let layout = RowLayout(parts: [.timer, .name, .branch, .gap], flexible: .branch)

        let row = makeRow(session, layout: layout)
        row.setFlexibleText("feature/probe", display: .fullName)

        XCTAssertEqual(
            row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue },
            ["0s", "Fix the row", "feature/probe"]
        )
    }

    /// The counters are one part and several symbols, so they have to be one view: the place
    /// the flexible part goes back to is counted in parts, and a block that spread itself over
    /// the row as three separate views would push that count off by two.
    func testCountersStandingBeforeThePartThatGivesWayDoNotShiftIt() {
        var session = testSession(
            title: "Fix the row",
            activities: [
                SessionActivity(id: "a", kind: .shell, startedAt: now),
                SessionActivity(id: "b", kind: .tool, startedAt: now),
            ],
            lastObservedAt: now
        )
        session.gitBranch = "feature/probe"
        let layout = RowLayout(parts: [.timer, .counters, .branch, .gap], flexible: .branch)

        let row = makeRow(session, layout: layout)
        row.setFlexibleText("feature/probe", display: .fullName)

        XCTAssertEqual(
            row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue },
            ["0s", "feature/probe"],
            "the branch went in after the counter block, not into the middle of it"
        )
    }

    /// Found by drawing a widget whose branch gives way: `main` came out in the name's own
    /// type, larger than every other qualifier in the row, purely because it was the part
    /// being shortened. Which part gives way is a decision about width, not about what the
    /// row is about — so a part is drawn the same whether or not it is the one that narrows.
    func testThePartThatGivesWayKeepsItsOwnType() {
        var session = testSession(title: "Fix the row", lastObservedAt: now)
        session.gitBranch = "feature/probe"
        let layout = RowLayout(parts: [.timer, .name, .branch, .gap], flexible: .branch)

        let row = makeRow(session, layout: layout)
        row.setFlexibleText("feature/probe", display: .fullName)

        let labels = row.arrangedSubviews.compactMap { $0 as? NSTextField }
        // The colour, not the font: both are the same size, and what set the branch apart in
        // the drawing was the name's full-strength foreground against the muted one every
        // other qualifier in the row is drawn in.
        XCTAssertEqual(
            labels.first { $0.stringValue == "feature/probe" }?.textColor,
            WidgetBackground.graphite.secondaryForegroundColor
        )
        XCTAssertEqual(
            labels.first { $0.stringValue == "Fix the row" }?.textColor,
            WidgetBackground.graphite.foregroundColor
        )
    }

    // MARK: - The dismiss button's column

    /// A session still at work gets no dismiss button at all, so without the column its
    /// counters sit a button-width further right than a finished session's and the two do not
    /// line up down the list. Measured rather than reasoned about: `furnitureWidth` is what
    /// the name budget is taken from, and it is the row laying itself out.
    func testKeepingTheColumnLinesUpAWorkingRowWithAFinishedOne() {
        let session = testSession(title: "Fix the row", lastObservedAt: now)
        let keepsColumn = RowLayout(parts: RowLayout.standard.parts, reservesDismissColumn: true)

        let working = makeRow(session, layout: keepsColumn, dismissal: .notOffered(until: now + 1_800))
        let finished = makeRow(session, layout: keepsColumn, dismissal: .now)

        XCTAssertEqual(working.furnitureWidth, finished.furnitureWidth, accuracy: 0.5)
    }

    /// And with the column given up, the two really do differ — otherwise the test above
    /// would pass for a reason that has nothing to do with the setting.
    func testGivingTheColumnUpLeavesTheWorkingRowWiderInside() {
        let session = testSession(title: "Fix the row", lastObservedAt: now)

        let working = makeRow(session, layout: .standard, dismissal: .notOffered(until: now + 1_800))
        let finished = makeRow(session, layout: .standard, dismissal: .now)

        XCTAssertLessThan(working.furnitureWidth, finished.furnitureWidth)
    }

    private func makeRow(
        _ snapshot: SessionSnapshot,
        layout: RowLayout,
        dismissal: RowDismissal? = nil
    ) -> HUDSessionRowView {
        HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            layout: layout,
            onFocus: {},
            dismissal: dismissal ?? .notOffered(until: now + 1_800),
            onRemove: {}
        )
    }
}
