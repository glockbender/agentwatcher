import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class HUDPanelHighlightTests: XCTestCase {
    func testHighlightAddsAnOverlayAboveTheWidgetContentWithoutInterceptingClicks() {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 104))

        panel.highlight()

        let overlay = panel.contentView?.subviews.compactMap { $0 as? HUDHighlightOverlayView }.last
        XCTAssertNotNil(overlay)
        XCTAssertNil(overlay?.hitTest(NSPoint(x: 20, y: 20)))
    }

    func testHighlightWaitsForUsableContentGeometry() {
        let panel = HUDPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(frame: .zero)

        panel.highlight()

        XCTAssertTrue(panel.contentView?.subviews.isEmpty ?? false)

        panel.contentView?.frame = NSRect(x: 0, y: 0, width: 360, height: 104)
        panel.updateHighlightOverlay()

        let overlay = panel.contentView?.subviews.compactMap { $0 as? HUDHighlightOverlayView }.last
        XCTAssertNotNil(overlay)
        XCTAssertTrue(overlay?.bounds.width.isFinite ?? false)
        XCTAssertTrue(overlay?.bounds.height.isFinite ?? false)
    }
}
