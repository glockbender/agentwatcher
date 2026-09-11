import AppKit
import XCTest

@testable import AgentWatchApp

/// The widget has no visible frame and its whole surface can be dragged, so the lit border
/// strip is the only thing that says whether a drag will move it or resize it.
@MainActor
final class WidgetEdgeHighlightTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 300, height: 120)

    // MARK: - Which strip a point belongs to

    func testEveryBorderStripHasAZoneAndTheMiddleHasNone() {
        let zones = WidgetEdgeHighlightView.edgeZones(in: bounds)

        XCTAssertEqual(zones.count, 8, "four edges and four corners")
        XCTAssertNil(
            WidgetEdgeHighlightView.zone(at: NSPoint(x: bounds.midX, y: bounds.midY), in: bounds),
            "the middle of the widget resizes nothing"
        )
    }

    /// A corner resizes in two directions at once, so where a corner and an edge overlap the
    /// corner is the more useful answer.
    func testACornerWinsOverTheEdgesItOverlaps() {
        let corner = NSPoint(x: bounds.minX + 1, y: bounds.minY + 1)

        XCTAssertEqual(WidgetEdgeHighlightView.zone(at: corner, in: bounds)?.edge, .bottomLeft)
    }

    func testEachSideAnswersWithItsOwnEdge() {
        func edge(at point: NSPoint) -> WidgetEdgeHighlightView.Edge? {
            WidgetEdgeHighlightView.zone(at: point, in: bounds)?.edge
        }

        XCTAssertEqual(edge(at: NSPoint(x: bounds.minX + 1, y: bounds.midY)), .left)
        XCTAssertEqual(edge(at: NSPoint(x: bounds.maxX - 1, y: bounds.midY)), .right)
        // Unflipped coordinates: the origin is at the bottom of the widget.
        XCTAssertEqual(edge(at: NSPoint(x: bounds.midX, y: bounds.minY + 1)), .bottom)
        XCTAssertEqual(edge(at: NSPoint(x: bounds.midX, y: bounds.maxY - 1)), .top)
    }

    /// A widget squeezed to nothing would be all border, and every point would claim to
    /// resize in some direction.
    func testAWidgetTooSmallToHaveEdgesClaimsNone() {
        XCTAssertTrue(WidgetEdgeHighlightView.edgeZones(in: NSRect(x: 0, y: 0, width: 8, height: 8)).isEmpty)
    }

    // MARK: - What gets lit

    func testASideIsLitAlongItsWholeLength() {
        let rects = WidgetEdgeHighlightView.highlightRects(for: .left, in: bounds)

        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, bounds.minX, "the band sits on the border, not beside it")
        XCTAssertEqual(rects[0].height, bounds.height)
        // Deeper than the band that gets painted: the stroke curves inward at each end of the
        // side, and a window as narrow as the stroke would cut those curves off.
        XCTAssertGreaterThan(rects[0].width, WidgetEdgeHighlightView.highlightThickness)
        XCTAssertEqual(rects[0].width, WidgetEdgeHighlightView.bandDepth)
    }

    /// A corner's own zone is six points square. Lit alone it reads as a speck, so both of
    /// its sides are lit for a short run instead.
    func testACornerLightsBothOfItsSides() {
        let rects = WidgetEdgeHighlightView.highlightRects(for: .bottomRight, in: bounds)

        XCTAssertEqual(rects.count, 2)
        for rect in rects {
            XCTAssertEqual(rect.maxX, bounds.maxX, accuracy: 0.01, "both bands reach the corner they mark")
            XCTAssertEqual(rect.minY, bounds.minY, accuracy: 0.01)
        }
    }

    func testNoBandEverLeavesTheWidget() {
        let edges: [WidgetEdgeHighlightView.Edge] = [
            .left, .right, .top, .bottom, .bottomLeft, .bottomRight, .topLeft, .topRight,
        ]

        for edge in edges {
            for rect in WidgetEdgeHighlightView.highlightRects(for: edge, in: bounds) {
                XCTAssertTrue(bounds.contains(rect), "\(edge) painted outside the widget")
            }
        }
    }

    /// A widget narrower than a corner's run would have both of a corner's bands cover the
    /// whole side, which reads as two full edges rather than a corner.
    func testACornerRunNeverExceedsTheWidget() {
        let narrow = NSRect(x: 0, y: 0, width: 40, height: 30)

        for rect in WidgetEdgeHighlightView.highlightRects(for: .topLeft, in: narrow) {
            XCTAssertTrue(narrow.contains(rect))
        }
    }

    // MARK: - The view

    /// The bug this class exists to keep fixed, and the reason the highlight is drawn at all
    /// rather than shown as a resize cursor. `cursorUpdate` is the event built for showing a
    /// cursor over an area, and it never arrives for an application that is not the active
    /// one — measured on a copy of this panel: 120 pointer movements, 120 `mouseMoved`, 0
    /// `cursorUpdate`. Movement is the only signal the background gets.
    func testTheZonesFollowMovementRatherThanWaitingForACursorUpdate() {
        let view = WidgetEdgeHighlightView(frame: bounds)
        view.updateTrackingAreas()

        XCTAssertFalse(view.trackingAreas.isEmpty)
        for area in view.trackingAreas {
            XCTAssertTrue(area.options.contains(.mouseMoved), "movement is what keeps the highlight in place")
            XCTAssertTrue(area.options.contains(.activeAlways), "the widget is hovered while another app is in front")
            XCTAssertFalse(
                area.options.contains(.cursorUpdate),
                "a background application is never told to update its cursor"
            )
        }
    }

    func testAnEdgeLightsUpAndTheMiddleDoesNot() {
        let view = WidgetEdgeHighlightView(frame: bounds)
        view.updateTrackingAreas()

        view.highlight(at: NSPoint(x: 1, y: bounds.midY))
        XCTAssertEqual(view.highlightedEdge, .left)

        view.highlight(at: NSPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertNil(view.highlightedEdge)
    }

    func testLockingTheSizePutsTheHighlightOut() {
        let view = WidgetEdgeHighlightView(frame: bounds)
        view.updateTrackingAreas()
        view.highlight(at: NSPoint(x: 1, y: bounds.midY))

        view.isResizable = false

        XCTAssertNil(view.highlightedEdge, "an edge that cannot be dragged must not offer to be")
        XCTAssertTrue(view.trackingAreas.isEmpty)
    }

    /// The widget grows itself when a session arrives, and that re-cuts the zones. Removing a
    /// tracking area sends no exit, so without this the band would stay lit with nothing left
    /// to put it out.
    func testRecuttingTheZonesUnderThePointerPutsTheHighlightOut() {
        let view = WidgetEdgeHighlightView(frame: bounds)
        view.updateTrackingAreas()
        view.highlight(at: NSPoint(x: 1, y: bounds.midY))

        view.updateTrackingAreas()

        XCTAssertNil(view.highlightedEdge)
    }

    // MARK: - The drag the strip performs

    /// The lit strip has to be the strip that resizes. Left to AppKit it was not: the window
    /// server takes a resize drag just outside the frame, while a press inside the frame
    /// reaches the window background and moves the widget — so the band marked the region
    /// that moved it, which is the opposite of what it says.
    func testTheLitStripTakesTheClickAndTheMiddleDoesNot() {
        let container = HUDContentContainer()
        container.frame = bounds
        container.setBody(NSView())
        let overlay = container.subviews.compactMap { $0 as? WidgetEdgeHighlightView }.last
        overlay?.frame = bounds

        XCTAssertTrue(overlay?.hitTest(NSPoint(x: 1, y: bounds.midY)) === overlay, "the edge resizes")
        XCTAssertNil(
            overlay?.hitTest(NSPoint(x: bounds.midX, y: bounds.midY)),
            "the middle still belongs to the widget, which is what makes it draggable"
        )
    }

    func testALockedWidgetLetsEveryClickThrough() {
        let container = HUDContentContainer()
        container.frame = bounds
        container.setBody(NSView())
        let overlay = container.subviews.compactMap { $0 as? WidgetEdgeHighlightView }.last
        overlay?.frame = bounds

        container.isResizable = false

        XCTAssertNil(overlay?.hitTest(NSPoint(x: 1, y: bounds.midY)), "a locked edge must not swallow a drag")
    }

    /// Screen coordinates: `y` grows upward, so dragging the bottom edge downward is a
    /// negative `dy` that lowers the origin and raises the height.
    func testDraggingEachSideMovesOnlyThatSide() {
        let initial = NSRect(x: 100, y: 200, width: 300, height: 120)
        let minimum = NSSize(width: 100, height: 50)

        func resized(_ edge: WidgetEdgeHighlightView.Edge, _ dx: CGFloat, _ dy: CGFloat) -> NSRect {
            WidgetEdgeHighlightView.resizedFrame(
                from: initial, edge: edge, delta: NSPoint(x: dx, y: dy), minimum: minimum)
        }

        XCTAssertEqual(resized(.right, 40, 0), NSRect(x: 100, y: 200, width: 340, height: 120))
        XCTAssertEqual(resized(.left, -40, 0), NSRect(x: 60, y: 200, width: 340, height: 120))
        XCTAssertEqual(resized(.top, 0, 30), NSRect(x: 100, y: 200, width: 300, height: 150))
        XCTAssertEqual(resized(.bottom, 0, -30), NSRect(x: 100, y: 170, width: 300, height: 150))
    }

    /// The strip has to stay lit for the whole drag, and staying lit is not automatic: the
    /// resize changes the widget's size on every frame, every size change re-cuts the zones,
    /// and re-cutting deliberately puts the highlight out. Left alone the band went dark on
    /// the first frame of the very drag it had just promised.
    func testTheBandStaysLitWhileTheEdgeIsBeingDragged() throws {
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        let container = HUDContentContainer()
        window.contentView = container
        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(container.subviews.last as? WidgetEdgeHighlightView)
        let press = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 1, y: overlay.bounds.midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        overlay.mouseDown(with: press)
        // What the resize itself does to this view: the widget is a different size, so the
        // zones are cut again.
        overlay.updateTrackingAreas()

        XCTAssertEqual(overlay.highlightedEdge, .left, "the strip being dragged must stay lit")

        // Dragging an edge outward takes the pointer off the widget, and the container
        // reports that as the pointer having left.
        container.mouseExited(with: NSEvent())
        XCTAssertEqual(overlay.highlightedEdge, .left, "the strip is captured for the whole drag")

        overlay.mouseUp(with: press)
        container.mouseExited(with: NSEvent())
        XCTAssertNil(overlay.highlightedEdge, "once the drag is over the pointer decides again")
    }

    func testACornerMovesBothOfItsSidesAtOnce() {
        let initial = NSRect(x: 100, y: 200, width: 300, height: 120)

        let frame = WidgetEdgeHighlightView.resizedFrame(
            from: initial,
            edge: .bottomLeft,
            delta: NSPoint(x: -40, y: -30),
            minimum: NSSize(width: 100, height: 50)
        )

        XCTAssertEqual(frame, NSRect(x: 60, y: 170, width: 340, height: 150))
    }

    /// A window that has shrunk as far as it goes must stop, not carry on walking across the
    /// screen: the edge being dragged stops while the opposite edge stays where it was.
    func testShrinkingPastTheMinimumHoldsTheOppositeEdgeStill() {
        let initial = NSRect(x: 100, y: 200, width: 300, height: 120)
        let minimum = NSSize(width: 220, height: 96)

        let frame = WidgetEdgeHighlightView.resizedFrame(
            from: initial, edge: .bottomLeft, delta: NSPoint(x: 500, y: 500), minimum: minimum)

        XCTAssertEqual(frame.size, minimum)
        XCTAssertEqual(frame.maxX, initial.maxX, "the right edge was not being dragged")
        XCTAssertEqual(frame.maxY, initial.maxY, "nor the top one")
    }

    // MARK: - The container

    /// A row reports the pointer leaving, but a row is rebuilt whenever an event arrives.
    /// A row replaced under a resting pointer never reports anything, so the container has
    /// to be the one that cannot miss it.
    func testTheContainerReportsThePointerLeavingTheWidget() {
        let container = HUDContentContainer()
        container.frame = bounds
        var left = false
        container.onPointerLeft = { left = true }
        container.updateTrackingAreas()

        XCTAssertFalse(container.trackingAreas.isEmpty)
        container.mouseExited(with: NSEvent())

        XCTAssertTrue(left)
    }

    func testThePointerLeavingTheWidgetPutsTheHighlightOut() throws {
        let container = HUDContentContainer()
        container.frame = bounds
        container.setBody(NSView())
        let overlay = try XCTUnwrap(container.subviews.last as? WidgetEdgeHighlightView)
        overlay.frame = bounds
        overlay.highlight(at: NSPoint(x: 1, y: bounds.midY))
        XCTAssertNotNil(overlay.highlightedEdge)

        container.mouseExited(with: NSEvent())

        XCTAssertNil(overlay.highlightedEdge, "a pointer that left fast can skip the strip's own exit")
    }

    /// The widget grows the moment the first session arrives, from the empty state to a
    /// list, and the zones are fixed rectangles rather than a share of the view. Until they
    /// were re-cut on a resize they went on describing the empty widget: measured at 340×56
    /// while the border had moved to 520×300, so the pointer crossed the real edge without
    /// entering any zone at all.
    func testTheZonesFollowTheWidgetWhenItGrows() throws {
        let container = HUDContentContainer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(container.subviews.last as? WidgetEdgeHighlightView)

        window.setContentSize(NSSize(width: 520, height: 300))
        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            overlay.trackingAreas.map(\.rect),
            WidgetEdgeHighlightView.edgeZones(in: overlay.bounds).map(\.rect),
            "the pointer has to find the border of the widget in front of it, not the one it used to be"
        )
    }

    /// Locking the size takes the zones away, and the widget can be resized by the app while
    /// locked — `Reset Widget Size` does exactly that. Unlocking then has to hand back zones
    /// for the widget as it is now, not as it was when the lock went on.
    func testUnlockingAfterAResizeGivesBackTheRightZones() throws {
        let container = HUDContentContainer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(container.subviews.last as? WidgetEdgeHighlightView)

        container.isResizable = false
        window.setContentSize(NSSize(width: 520, height: 300))
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.trackingAreas.isEmpty, "a locked edge offers nothing while it is locked")

        container.isResizable = true

        XCTAssertEqual(
            overlay.trackingAreas.map(\.rect),
            WidgetEdgeHighlightView.edgeZones(in: overlay.bounds).map(\.rect),
            "the zones come back for the widget in front of the pointer"
        )
    }

    /// The widget rebuilds its whole body about twice a second. A pointer resting on an edge
    /// sends no event while that happens, so a rebuild that put the highlight out would leave
    /// the edge dark until the pointer moved again.
    func testARefreshUnderARestingPointerLeavesTheHighlightAlone() throws {
        let container = HUDContentContainer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(container.subviews.last as? WidgetEdgeHighlightView)
        overlay.highlight(at: NSPoint(x: 1, y: 60))

        container.setBody(NSView())
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.highlightedEdge, .left)
    }

    func testSwappingTheBodyKeepsTheEdgeOverlay() {
        let container = HUDContentContainer()
        let first = NSView()
        let second = NSView()

        container.setBody(first)
        container.setBody(second)

        XCTAssertTrue(container.body === second)
        XCTAssertFalse(container.subviews.contains(first), "the old body is gone")
        XCTAssertEqual(
            container.subviews.compactMap { $0 as? WidgetEdgeHighlightView }.count,
            1,
            "the overlay carries tracking areas and has to outlive a refresh"
        )
        XCTAssertTrue(
            container.subviews.last is WidgetEdgeHighlightView,
            "the overlay stays on top, or its zones would be covered by the body"
        )
    }
}
