import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// Locking must stop the *user* from moving or resizing the widget without stopping the
/// app from repositioning it when it sizes itself to a new session count.
@MainActor
final class HUDPanelLockTests: XCTestCase {

    // MARK: - What the settings do to the window

    /// Replaces four assertions on a three-line struct that mapped two booleans to three
    /// negated booleans. That struct could not be wrong in any way that mattered, and its
    /// tests would have stayed green with the locks never applied to a window at all — which
    /// its own documentation admitted. This drives the same settings through the controller
    /// and asks the panel.
    func testLockingAndUnlockingReachesBothDragSurfacesAndTheResize() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let controller = makeController(preferences: preferences, settings: settings)
        defer { controller.shutdown() }
        let panel = try XCTUnwrap(controller.window as? HUDPanel)

        XCTAssertTrue(panel.isMovable)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.styleMask.contains(.resizable))

        settings.setLocksPosition(true)
        controller.refreshInteractionLocks()
        // Both surfaces: the panel is `.titled` with a transparent bar, so the title strip
        // stays draggable unless `isMovable` is cleared as well as the background.
        XCTAssertFalse(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.styleMask.contains(.resizable), "locking the position must not freeze the size")

        settings.setLocksSize(true)
        controller.refreshInteractionLocks()
        XCTAssertFalse(panel.styleMask.contains(.resizable))

        settings.setLocksPosition(false)
        controller.refreshInteractionLocks()
        XCTAssertTrue(panel.isMovable, "unlocking the position must give both surfaces back")
        XCTAssertFalse(panel.styleMask.contains(.resizable), "and must leave the size lock alone")
    }

    /// The lock stops a drag, not the application. A widget left on a display that has since
    /// been unplugged has to have a way home without turning the lock off first.
    func testALockedWidgetCanStillBeSentBackToTheMiddleOfTheScreen() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        settings.setLocksPosition(true)
        let controller = makeController(preferences: preferences, settings: settings)
        defer { controller.shutdown() }

        let panel = try XCTUnwrap(controller.window)
        let visibleFrame = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)

        controller.resetPosition()

        // Whole points, because that is what the window server rounds an origin to.
        let centred = HUDPlacement.centeredOrigin(for: panel.frame.size, in: visibleFrame)
        XCTAssertEqual(panel.frame.midX, centred.x + panel.frame.width / 2, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, centred.y + panel.frame.height / 2, accuracy: 1)
        XCTAssertEqual(
            HUDFrameStore(preferences: preferences).savedOrigin,
            panel.frame.origin,
            "the widget must still be there after a restart"
        )
    }

    /// Toggling the lock rebuilds the window's frame view, and the rebuilt frame arrives
    /// with a fresh, visible set of standard buttons. A widget that hides its title bar then
    /// showed traffic lights sitting on top of its first session row.
    func testTheWindowButtonsStayHiddenAcrossASizeLockToggle() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let controller = makeController(preferences: preferences, settings: settings)
        defer { controller.shutdown() }
        let panel = try XCTUnwrap(controller.window as? HUDPanel)

        settings.setLocksSize(true)
        controller.refreshInteractionLocks()
        settings.setLocksSize(false)
        controller.refreshInteractionLocks()

        XCTAssertTrue(panel.styleMask.contains(.resizable), "unlocking has to give the resize back")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(panel.standardWindowButton(button)?.isHidden, true, "\(button) came back visible")
        }
    }

    private func makeController(preferences: PreferenceFile, settings: WidgetSettingsStore) -> HUDPanelController {
        HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: HUDFrameStore(preferences: preferences),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
    }

    // MARK: - What AppKit still allows once they are applied

    func testALockedWidgetCanStillBeRepositionedByTheApp() {
        let panel = makePanel()
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.styleMask.remove(.resizable)

        // Resizing first: `setContentSize` grows the window downward from its top-left,
        // so it moves the origin and would mask what the repositioning assertion checks.
        panel.setContentSize(NSSize(width: 400, height: 200))
        panel.setFrameOrigin(NSPoint(x: 320, y: 240))

        XCTAssertEqual(panel.frame.origin, NSPoint(x: 320, y: 240))
        XCTAssertEqual(panel.frame.size.width, 400)
    }

    func testTheResizableFlagTogglesWithoutRebuildingTheWindow() {
        let panel = makePanel()

        panel.styleMask.remove(.resizable)
        XCTAssertFalse(panel.styleMask.contains(.resizable))

        panel.styleMask.insert(.resizable)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
    }

    /// Pins the reason the widget assigns `contentView` and never `contentViewController`.
    ///
    /// Setting a content view *controller* resizes the window to the new view's fitting
    /// size. For a scroll view with no intrinsic height that is the window minimum, so every
    /// refresh — twice a second — collapsed the widget and undid the resize the user had
    /// just finished. The two assertions below are the before and after of that bug.
    func testAssigningAContentViewControllerCollapsesTheWindowButAContentViewDoesNot() {
        let panel = makePanel()
        panel.minSize = NSSize(width: 220, height: 96)

        panel.setContentSize(NSSize(width: 500, height: 300))
        panel.contentViewController = makeSmallFittingSizeController()
        XCTAssertEqual(
            panel.frame.size,
            panel.minSize,
            "AppKit resizes the window down to the controller's fitting size — this is the trap"
        )

        panel.setContentSize(NSSize(width: 500, height: 300))
        panel.contentView = NSView()
        XCTAssertEqual(panel.frame.size, NSSize(width: 500, height: 300))
    }

    /// Stands in for the session list, whose scroll view has no intrinsic height and
    /// therefore reports a fitting size far below whatever the user dragged.
    private func makeSmallFittingSizeController() -> NSViewController {
        let controller = NSViewController(nibName: nil, bundle: nil)
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 100),
            view.heightAnchor.constraint(equalToConstant: 40),
        ])
        controller.view = view
        return controller
    }

    private func makePanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}

/// The bundle identifier is the sole gate on closing Codex sessions when its app quits, and
/// on never doing that to a Claude session running in a terminal.
@MainActor
final class AgentDesktopApplicationTests: XCTestCase {
    func testOnlyCodexHasAHostingDesktopApplication() {
        XCTAssertEqual(AgentSource.codex.desktopBundleIdentifier, "com.openai.codex")
        XCTAssertNil(
            AgentSource.claude.desktopBundleIdentifier,
            "Claude Code runs in a terminal; quitting Claude.app must not close its sessions"
        )
    }

    func testTheIdentifierRoundTripsAndRejectsEverythingElse() {
        XCTAssertEqual(AgentSource(desktopBundleIdentifier: "com.openai.codex"), .codex)
        XCTAssertNil(AgentSource(desktopBundleIdentifier: "com.anthropic.claudefordesktop"))
        XCTAssertNil(AgentSource(desktopBundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(
            AgentSource(desktopBundleIdentifier: nil),
            "an application terminating without an identifier must close nothing"
        )
    }
}

/// Two sources of invisible vertical space, both measured on a live window before being
/// removed. Together they put roughly fifty points of emptiness above the first session.
@MainActor
final class HUDListPaddingTests: XCTestCase {
    /// A scroll view in a window with a title bar inserts a top inset of its own. This
    /// widget hides that bar and draws through it, so the inset is pure empty space.
    func testTheScrollViewAddsNoInsetOfItsOwn() {
        let scrollView = NSScrollView()

        XCTAssertTrue(
            scrollView.automaticallyAdjustsContentInsets,
            "AppKit's default is what the widget has to switch off"
        )

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()

        XCTAssertEqual(scrollView.contentInsets.top, 0)
    }

    /// A plain stack is not flipped, so a document view shorter than its scroll view sinks
    /// to the bottom and the slack collects above the first row.
    func testTheRowStackFillsFromTheTop() {
        XCTAssertTrue(FlippedStackView().isFlipped)
        XCTAssertFalse(NSStackView().isFlipped, "which is exactly why the widget cannot use one")
    }

    /// The mechanism, asserted directly: a clip view takes its orientation from its document
    /// view, and that is what decides whether a short list fills from the top or the bottom.
    func testAFlippedDocumentViewMakesTheClipViewFillFromTheTop() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        scrollView.documentView = NSStackView()
        XCTAssertFalse(scrollView.contentView.isFlipped)

        scrollView.documentView = FlippedStackView()
        XCTAssertTrue(scrollView.contentView.isFlipped)
    }
}
