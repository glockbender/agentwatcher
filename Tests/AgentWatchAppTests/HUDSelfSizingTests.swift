import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The widget grows with the number of sessions until someone gives it a size of their own.
///
/// Only the height calculation was tested before, never the window actually following it —
/// and the rule moved from "no size has been saved" to a setting of its own, so this is the
/// seam that had to be measured rather than reasoned about.
@MainActor
final class HUDSelfSizingTests: XCTestCase {
    func testTheHeightFollowsTheSessionCount() throws {
        let (controller, _) = try makeController()

        controller.render(WidgetState(sessions: sessions(1)))
        let withOne = try height(of: controller)
        controller.render(WidgetState(sessions: sessions(5)))
        let withFive = try height(of: controller)

        XCTAssertGreaterThan(withFive, withOne, "five rows need more room than one")
    }

    func testASizeChosenByHandStopsTheHeightFromMoving() throws {
        let (controller, frameStore) = try makeController()
        controller.render(WidgetState(sessions: sessions(5)))

        // The order a finished drag happens in: the window is already the new size, and the
        // store is told about it afterwards. `save` records a size, it does not apply one.
        try XCTUnwrap(controller.window).setContentSize(NSSize(width: 380, height: 300))
        frameStore.save(NSSize(width: 380, height: 300))
        controller.render(WidgetState(sessions: sessions(1)))

        XCTAssertEqual(try height(of: controller), 300, accuracy: 0.5)
    }

    /// A reset goes back to the size a fresh install has, not to the size the widget had
    /// before it was resized by hand — and from there the height follows the sessions again.
    func testResettingTheSizeStartsItFollowingAgain() throws {
        let (controller, frameStore) = try makeController()
        try XCTUnwrap(controller.window).setContentSize(NSSize(width: 380, height: 300))
        frameStore.save(NSSize(width: 380, height: 300))
        controller.render(WidgetState(sessions: sessions(1)))

        controller.resetSize()
        let withOne = try height(of: controller)
        controller.render(WidgetState(sessions: sessions(6)))

        XCTAssertLessThan(withOne, 300, "the reset drops the size that was chosen by hand")
        XCTAssertGreaterThan(try height(of: controller), withOne, "and the height follows again")
    }

    /// The frame, which for this panel is the content: it is `.fullSizeContentView`, so
    /// `setContentSize` sets the frame height and `contentLayoutRect` is 28 points shorter —
    /// the title bar the widget draws over. The frame is what `resizeIfSelfSizing` compares.
    private func height(of controller: HUDPanelController) throws -> CGFloat {
        try XCTUnwrap(controller.window).frame.height
    }

    private func sessions(_ count: Int) -> [SessionSnapshot] {
        (0..<count).map { index in
            testSession(index: index, title: "session \(index)", phase: .executing, lastObservedAt: Date())
        }
    }

    private func makeController() throws -> (HUDPanelController, HUDFrameStore) {
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
        return (controller, frameStore)
    }
}
