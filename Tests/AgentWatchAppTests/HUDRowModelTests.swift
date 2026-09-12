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
            HUDRowModel(snapshot: session, now: now, showsSessionTopic: true),
            HUDRowModel(snapshot: session, now: now.addingTimeInterval(60), showsSessionTopic: true)
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

        XCTAssertFalse(
            HUDRowModel(snapshot: waiting, now: justBeforeTheThreshold, showsSessionTopic: true)
                .isDismissible)
        XCTAssertTrue(
            HUDRowModel(snapshot: waiting, now: atTheThreshold, showsSessionTopic: true).isDismissible)
    }

    /// Turning the topic off is a change to what the row draws, so it has to be a change to
    /// the model — otherwise the setting would appear not to work until the next event.
    func testHidingTheTopicTakesTheNameOutOfTheModel() {
        let session = testSession(title: "Переписать ingress", lastObservedAt: now)

        XCTAssertEqual(
            HUDRowModel(snapshot: session, now: now, showsSessionTopic: true).name,
            "Переписать ingress"
        )
        XCTAssertNil(HUDRowModel(snapshot: session, now: now, showsSessionTopic: false).name)
    }
}
