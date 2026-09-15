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

    private func makeRow(_ snapshot: SessionSnapshot, layout: RowLayout) -> HUDSessionRowView {
        HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            layout: layout,
            onFocus: {},
            dismissal: .notOffered(until: now + 1_800),
            onRemove: {}
        )
    }
}
