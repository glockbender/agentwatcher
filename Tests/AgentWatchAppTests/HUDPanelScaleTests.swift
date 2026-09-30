import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// What the widget does when its look or its size changes from the settings window: the rows
/// on screen follow at once, the window says where it is, and its floor moves with the size.
@MainActor
final class HUDPanelScaleTests: XCTestCase {
    /// A recoloured lamp reaches the row already on screen. Nothing tells the widget a theme
    /// has moved but `setAppearance`, which is the seam this checks.
    func testARecolouredPhaseRepaintsTheRowOnScreen() throws {
        let (controller, _, _) = try makeController()
        defer { controller.shutdown() }
        controller.render(
            WidgetState(sessions: [testSession(index: 0, title: "one", phase: .executing, lastObservedAt: Date())]))
        XCTAssertEqual(
            Self.lamp(in: controller)?.paintedColor?.srgbHex, SessionPhase.executing.defaultLampStyle.color.srgbHex)

        var scheme = LampScheme()
        scheme.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .executing)
        controller.setAppearance(background: .graphite, lampScheme: scheme, opacity: 1)

        XCTAssertEqual(Self.lamp(in: controller)?.paintedColor?.srgbHex, "#FF0000")
    }

    /// A person choosing a size is looking at the settings window, and the thing that changes
    /// is a small window elsewhere — behind something, or one they have lost track of. So a
    /// change of size says where the widget is, with the outline that showing it draws.
    func testChangingTheSizeSaysWhereTheWidgetIs() throws {
        let (controller, panel) = try makeWidgetOnScreen()
        defer { controller.shutdown() }

        controller.setScale(2)

        XCTAssertNotNil(Self.outline(in: panel), "the widget changed size without saying which window it was")
    }

    /// Reset Size and Reset Position are pressed by somebody who has lost the widget, and the
    /// middle of the main screen is still a place they have to find.
    func testPuttingTheSizeBackSaysWhereTheWidgetIs() throws {
        let (controller, panel) = try makeWidgetOnScreen()
        defer { controller.shutdown() }

        controller.resetSize()

        XCTAssertNotNil(Self.outline(in: panel), "the widget changed size without saying which window it was")
    }

    func testPuttingThePositionBackSaysWhereTheWidgetIs() throws {
        let (controller, panel) = try makeWidgetOnScreen()
        defer { controller.shutdown() }

        controller.resetPosition()

        XCTAssertNotNil(Self.outline(in: panel), "the widget moved without saying which window it was")
    }

    /// Through the store's own `onChange`, the way the running app is wired: the seam is the
    /// one between a size being written and the widget hearing about it.
    func testEnlargingTheWidgetRedrawsTheRowsAtOnce() throws {
        let (controller, settings, _) = try makeController()
        defer { controller.shutdown() }
        settings.onChange = { setting in
            if case .scale = setting {
                controller.setScale(settings.scale)
            }
        }
        // Wide enough that the new size's floor cannot move it. A widget that grows to meet
        // the floor changes its own width, and the list is rebuilt for a width change on its
        // own — which would let this pass with the scale never compared at all.
        try XCTUnwrap(controller.window).setContentSize(NSSize(width: 600, height: 400))
        controller.render(
            WidgetState(sessions: [testSession(index: 0, title: "one", phase: .executing, lastObservedAt: Date())]))
        let widthBefore = try XCTUnwrap(controller.window).frame.width
        let before = try XCTUnwrap(controller.visibleRows.first)
        before.layoutSubtreeIfNeeded()
        let beforeHeight = before.frame.height

        settings.setScale(2)

        let after = try XCTUnwrap(controller.visibleRows.first)
        after.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try XCTUnwrap(controller.window).frame.width, widthBefore,
            "the widget did not change width, so only the scale can have rebuilt the row")
        XCTAssertFalse(after === before, "the row on screen is the old one, drawn at its old size")
        XCTAssertGreaterThan(after.frame.height, beforeHeight)
        XCTAssertEqual(after.frame.height, WidgetStyle(scale: 2).rowHeight, accuracy: 0.5)
    }

    /// A widget parked at its smallest is below the floor the moment the scale grows, and
    /// macOS does not grow a window to meet a minimum it has just been handed.
    func testTheWidgetGrowsPastTheFloorItUsedToSitOn() throws {
        let (controller, _, frameStore) = try makeController()
        defer { controller.shutdown() }
        let panel = try XCTUnwrap(controller.window)
        panel.setContentSize(WidgetStyle.standard.minimumWindowSize)

        controller.setScale(2)

        let floor = WidgetStyle(scale: 2).minimumWindowSize
        XCTAssertEqual(panel.minSize, floor, "the widget may still be dragged smaller than it draws")
        XCTAssertGreaterThanOrEqual(panel.frame.height, floor.height)
        XCTAssertGreaterThanOrEqual(panel.frame.width, floor.width)
        // Growing to meet the floor is the app's doing, not a size the person chose: kept as
        // one, it would end the widget sizing itself to the number of its sessions.
        XCTAssertTrue(frameStore.sizeFollowsSessions, "changing the size turned off the widget sizing itself")
    }

    /// The window and the preferences file both clamp the size, and they have to agree: a size
    /// the window allows and the file rounds up springs back on the next launch.
    func testTheSavedSizeIsHeldToTheSameFloorTheWindowIs() throws {
        let (controller, _, frameStore) = try makeController()
        defer { controller.shutdown() }
        let panel = try XCTUnwrap(controller.window)

        controller.setScale(WidgetSettingsStore.minimumScale)

        let floor = WidgetStyle(scale: WidgetSettingsStore.minimumScale).minimumWindowSize
        XCTAssertEqual(panel.minSize, floor)
        frameStore.save(floor)
        XCTAssertEqual(frameStore.size, floor)
    }

    /// And the floor is in force before the widget is built: the window is created from the
    /// size on file, and a store still holding the larger floor would round a smaller saved
    /// size up before anything said otherwise.
    func testAWidgetLeftBelowTheLargerFloorOpensAtTheSizeItWasLeftAt() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        settings.setScale(WidgetSettingsStore.minimumScale)
        let smallest = WidgetStyle(scale: settings.scale).minimumWindowSize
        let saving = HUDFrameStore(preferences: preferences)
        saving.minimumSize = smallest
        saving.save(smallest)

        let controller = HUDPanelController(
            reach: { _ in .nowhere }, focus: { _ in .nothingRaised }, remove: { _ in }, background: .graphite,
            lampScheme: LampScheme(), backgroundOpacity: 1, style: WidgetStyle(scale: settings.scale),
            frameStore: HUDFrameStore(preferences: preferences), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences))
        defer { controller.shutdown() }
        controller.showWindow(nil)

        XCTAssertEqual(
            try XCTUnwrap(controller.window).frame.size, smallest,
            "the widget opened at the larger floor instead of the size it was left at")
    }

    private func makeController() throws -> (HUDPanelController, WidgetSettingsStore, HUDFrameStore) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let frameStore = HUDFrameStore(preferences: preferences)
        let controller = HUDPanelController(
            reach: { _ in .nowhere }, focus: { _ in .nothingRaised }, remove: { _ in }, background: .graphite,
            lampScheme: LampScheme(), backgroundOpacity: 1, style: WidgetStyle(scale: settings.scale),
            frameStore: frameStore, settings: settings, rowLayouts: RowLayoutStore(preferences: preferences))
        controller.showWindow(nil)
        return (controller, settings, frameStore)
    }

    /// At a real size, with nothing lit yet: the outline is laid out against the content, and
    /// against nothing it waits for geometry rather than drawing.
    private func makeWidgetOnScreen() throws -> (HUDPanelController, HUDPanel) {
        let (controller, _, _) = try makeController()
        let panel = try XCTUnwrap(controller.window as? HUDPanel)
        panel.setContentSize(NSSize(width: 600, height: 400))
        XCTAssertNil(Self.outline(in: panel), "the widget is lit before anything happened")
        return (controller, panel)
    }

    private static func outline(in panel: HUDPanel) -> HUDHighlightOverlayView? {
        panel.contentView?.subviews.compactMap { $0 as? HUDHighlightOverlayView }.last
    }

    private static func lamp(in controller: HUDPanelController) -> SessionLampView? {
        guard let root = controller.window?.contentView else {
            return nil
        }
        root.layoutSubtreeIfNeeded()
        func first(in view: NSView) -> SessionLampView? {
            (view as? SessionLampView) ?? view.subviews.lazy.compactMap(first).first
        }
        return first(in: root)
    }
}
