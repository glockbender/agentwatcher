import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The movements a theme sets outside the widget: the menu bar's grid and sphere, and the
/// menu's marks. Checked on the layers and frames the screen is given, since nothing here can
/// look at the bar.
@MainActor
final class ThemeMotionTests: XCTestCase {
    private func use(_ change: (inout WidgetTheme.Look) -> Void) {
        let (look, phases) = (ThemeInUse.look, ThemeInUse.phases)
        addTeardownBlock { (ThemeInUse.look, ThemeInUse.phases) = (look, phases) }
        var changed = WidgetTheme.standard.dark
        change(&changed)
        ThemeInUse.look = changed
    }

    private func cells(needsPerson: Int = 1, working: Int = 1, done: Int = 1, quiet: Int = 1) -> [MenuBarIconCell] {
        MenuBarIconCell.cells(
            for: SessionAttentionCounts(needsPerson: needsPerson, working: working, done: done, quiet: quiet))
    }

    // MARK: - The grid

    /// Any state can breathe, at the rhythm its theme gives it, and a still one holds still.
    func testTheGridBreathesTheStatesAndRhythmsTheThemeSays() {
        use { look in
            look.setMarkMotion(.steady, fadeTo: .white, cycle: 1.4, for: .needsPerson)
            look.setMarkMotion(.dim, fadeTo: .white, cycle: 3, for: .done)
        }
        let view = MenuBarIconView()

        view.show(cells())

        XCTAssertEqual(view.breathingCells, [1, 2], "working as shipped, and done as the theme asks")
        XCTAssertEqual(view.breathPeriods, [1.4, 3])
    }

    /// A cell told to fade to a second colour does, and does not breathe as well.
    func testAGridCellFadesToTheColourTheThemeGives() {
        use { look in
            look.setMarkMotion(.gradient, fadeTo: NSColor(sRGB: "#FF0000"), cycle: 2, for: .needsPerson)
        }
        let view = MenuBarIconView()

        view.show(cells())

        XCTAssertEqual(view.fadingCells, [0])
        XCTAssertEqual(view.breathingCells, [1])
    }

    /// Movement still means "there is something here": an empty cell holds still whatever the
    /// theme says.
    func testAnEmptyCellHoldsStillWhateverTheThemeSays() {
        use { look in
            look.setMarkMotion(.gradient, fadeTo: NSColor(sRGB: "#FF0000"), cycle: 2, for: .needsPerson)
        }
        let view = MenuBarIconView()

        view.show(cells(needsPerson: 0))

        XCTAssertEqual(view.fadingCells, [])
    }

    // MARK: - The sphere

    /// Each of the sphere's movements can be switched off, and the halo's breath timed.
    func testTheSphereMovesOnlyAsTheThemeAllows() {
        use { look in
            look.sphere.sway = false
            look.sphere.haloCycle = 6
        }
        let view = MenuBarIconView()

        view.show(cells(), as: .sphere)

        XCTAssertEqual(view.swayingCells, [])
        XCTAssertEqual(view.breathPeriods, [6])
    }

    func testASphereToldNotToSwellDoesNotWhenACountMoves() {
        use { $0.sphere.swell = false }
        let view = MenuBarIconView()
        view.show(cells(needsPerson: 0), as: .sphere)

        view.show(cells(needsPerson: 2), as: .sphere)

        XCTAssertEqual(view.swellingCells, [])
    }

    /// A theme that changes only how the sphere moves still reaches it: the counts and colours
    /// are the same, and the view skips a drawing that changes nothing it compares.
    func testAThemeThatOnlyChangesTheSpheresMovementsRedrawsIt() {
        let view = MenuBarIconView()
        view.show(cells(), as: .sphere)
        XCTAssertEqual(view.swayingCells, [0])

        use { $0.sphere.sway = false }
        view.show(cells(), as: .sphere)

        XCTAssertEqual(view.swayingCells, [])
    }

    /// With the menu bar matched to the lamps, a new colour on a lead lamp reaches the sphere
    /// on the next drawing the theme change asks for.
    func testANewLeadLampColourRedrawsTheSphere() throws {
        use { $0.setFollowsLamps(true) }
        let view = MenuBarIconView()
        view.show(cells(needsPerson: 1, working: 0, done: 0, quiet: 0), as: .sphere)
        let before = view.cellContents.first.map { $0 as AnyObject }

        use {
            $0.setFollowsLamps(true)
            $0.changeLampStyle(for: .waitingForUser) { $0.color = NSColor(sRGB: "#00FF00") }
        }
        view.show(cells(needsPerson: 1, working: 0, done: 0, quiet: 0), as: .sphere)

        XCTAssertFalse(view.cellContents.first.map { $0 as AnyObject } === before, "the sphere kept its old picture")
        XCTAssertEqual(cells(needsPerson: 1).first?.accent.srgbHex, "#00FF00")
    }

    // MARK: - The menu's marks

    /// A dimmed mark is the same mark drawn fainter halfway through its breath, and whole at
    /// the start of it.
    func testAMenuMarkIsFaintestHalfwayThroughItsBreath() throws {
        let style = LampStyle(color: NSColor(sRGB: "#FF9F0A"), motion: .dim, animationCycle: 2)

        let start = try alpha(of: XCTUnwrap(MenuMarkAnimator.frame(of: style, attention: .needsPerson, at: 10)))
        let halfway = try alpha(of: XCTUnwrap(MenuMarkAnimator.frame(of: style, attention: .needsPerson, at: 11)))

        XCTAssertEqual(start, 1, accuracy: 0.02)
        XCTAssertEqual(halfway, 1 - SessionAttention.needsPerson.breathDepth, accuracy: 0.05)
    }

    /// The menu's marks move only while it is open, only when the theme asks, and stop when it
    /// closes.
    func testTheMenusMarksMoveOnlyWhileItIsOpenAndOnlyWhenAsked() throws {
        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        let host = FakeStatusMenuHost()
        addTeardownBlock { _ = host }
        let menu = StatusMenu(settings: settings, host: host)
        host.sessions = [testSession(index: 0, title: "Waiting", phase: .waitingForUser, lastObservedAt: .now)]

        menu.menuWillOpen(menu.menu)
        XCTAssertFalse(menu.marks.isRunning, "the built-in theme holds the marks still")
        menu.menuDidClose(menu.menu)

        use { $0.menuMotion = .lamp }
        menu.menuWillOpen(menu.menu)
        XCTAssertTrue(menu.marks.isRunning)
        menu.refreshSessions()
        XCTAssertTrue(menu.marks.isRunning, "lines shown again in an open menu keep moving")

        menu.menuDidClose(menu.menu)
        XCTAssertFalse(menu.marks.isRunning)
    }

    /// The alpha at the middle of the image, where the disc is.
    private func alpha(of image: NSImage) throws -> CGFloat {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        // Just off the middle, on the disc rather than on the mark cut into it.
        return try XCTUnwrap(rep.colorAt(x: 5, y: 16)).alphaComponent
    }
}
