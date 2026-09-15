import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// A template chosen in the settings window has to reach the widget, and reach it at once.
///
/// The seam between the two is a store, a callback in `AppDelegate` and `refreshSettings` —
/// and everything either side of it had tests while the path through it had none. What makes
/// it worth a test of its own is that the widget deliberately refuses to rebuild a row when
/// nothing about the session changed: that is what keeps the row under the pointer alive, and
/// it is also exactly what would swallow a change of template.
@MainActor
final class RowLayoutTakesEffectTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testATemplateChosenAfterTheWidgetIsDrawnRebuildsItsRows() throws {
        let (controller, rowLayouts) = try makeController()
        var session = testSession(index: 0, title: "Fix the row", lastObservedAt: now)
        session.gitBranch = "row-format"
        controller.render(WidgetState(sessions: [session]))
        let before = try XCTUnwrap(controller.currentRow(for: session.id))
        XCTAssertFalse(before.drawnParts.contains(.branch))

        rowLayouts.setLayout(
            RowLayout(parts: [.timer, .lamp, .agent, .name, .gap, .branch, .context], flexible: .name)
        )
        // What `AppDelegate` does when the store reports a change, and nothing more: no new
        // event about the session, because a person changing a setting is not a session
        // saying anything.
        controller.refreshSettings()

        let after = try XCTUnwrap(controller.currentRow(for: session.id))
        XCTAssertTrue(after.drawnParts.contains(.branch), "the row was never rebuilt for the new template")
    }

    /// And the same refresh with nothing changed leaves the rows where they are — the row
    /// under the pointer survives a setting somebody else changed.
    func testARefreshThatChangesNoTemplateKeepsTheRowsItHas() throws {
        let (controller, _) = try makeController()
        let session = testSession(index: 0, title: "Fix the row", lastObservedAt: now)
        controller.render(WidgetState(sessions: [session]))
        let before = try XCTUnwrap(controller.currentRow(for: session.id))

        controller.refreshSettings()

        XCTAssertTrue(controller.currentRow(for: session.id) === before)
    }

    private func makeController() throws -> (HUDPanelController, RowLayoutStore) {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let rowLayouts = RowLayoutStore(preferences: preferences)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: rowLayouts
        )
        controller.showWindow(nil)
        return (controller, rowLayouts)
    }
}
