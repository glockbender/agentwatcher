import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class WidgetSettingsWindowTests: XCTestCase {
    func testEveryPhaseGetsARowThatExplainsItself() throws {
        let window = try makeWindow().controller

        for phase in SessionPhase.allCases {
            let well = try XCTUnwrap(window.colorWells[phase], "\(phase) has no colour")
            let motion = try XCTUnwrap(window.motionButtons[phase], "\(phase) has no motion")
            XCTAssertEqual(well.toolTip, phase.explanation)
            XCTAssertEqual(motion.toolTip, phase.explanation)
            XCTAssertEqual(
                motion.itemTitles,
                SessionLampAppearance.Motion.allCases.map(\.title),
                "every phase offers the same three motions"
            )
        }
    }

    func testAColourChosenInARowIsStoredForThatPhaseAlone() throws {
        let (controller, lampSchemes, _) = try makeWindow()
        let well = try XCTUnwrap(controller.colorWells[.failed])

        well.color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        well.sendAction(well.action, to: well.target)

        let scheme = lampSchemes.scheme
        XCTAssertEqual(scheme.style(for: .failed).color.srgbHex, "#00FF00")
        XCTAssertEqual(
            scheme.style(for: .executing).color.srgbHex,
            SessionPhase.executing.defaultLampStyle.color.srgbHex,
            "the row next to it is untouched"
        )
    }

    func testStoppingTheBlinkOnARowIsStored() throws {
        let (controller, lampSchemes, _) = try makeWindow()
        let motion = try XCTUnwrap(controller.motionButtons[.waitingForUser])

        motion.selectItem(withTitle: SessionLampAppearance.Motion.steady.title)
        motion.sendAction(motion.action, to: motion.target)

        XCTAssertEqual(lampSchemes.scheme.style(for: .waitingForUser).motion, .steady)
    }

    func testTheWindowOpensShowingWhatWasChosenBefore() throws {
        let preferences = try isolatedPreferences()
        let lampSchemes = LampSchemeStore(preferences: preferences)
        lampSchemes.setMotion(.urgent, for: .idle)
        lampSchemes.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .idle)

        let controller = WidgetSettingsWindowController(
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: lampSchemes
        )

        XCTAssertEqual(
            controller.motionButtons[.idle]?.titleOfSelectedItem,
            SessionLampAppearance.Motion.urgent.title
        )
        XCTAssertEqual(controller.colorWells[.idle]?.color.srgbHex, "#FF0000")
    }

    func testResetPutsEveryRowBackToTheAppsOwnLamp() throws {
        let (controller, lampSchemes, _) = try makeWindow()
        let motion = try XCTUnwrap(controller.motionButtons[.executing])
        motion.selectItem(withTitle: SessionLampAppearance.Motion.steady.title)
        motion.sendAction(motion.action, to: motion.target)

        controller.resetLamp()

        XCTAssertTrue(lampSchemes.scheme.isDefault)
        XCTAssertEqual(
            motion.titleOfSelectedItem,
            SessionPhase.executing.defaultLampStyle.motion.title,
            "the control has to show the lamp the app went back to"
        )
    }

    func testExactlyOneBackgroundIsMarked() throws {
        let (controller, _, backgroundStore) = try makeWindow()
        let mint = try XCTUnwrap(controller.backgroundButtons[.mint])

        mint.performClick(nil)

        XCTAssertEqual(backgroundStore.selected, .mint)
        XCTAssertEqual(controller.backgroundButtons.values.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(mint.state, .on)
    }

    /// The floor is the point: at zero the widget disappears and the person who made it
    /// disappear cannot find it again. The slider must not be able to ask for that.
    func testTheOpacitySliderCannotReachInvisible() throws {
        let controller = try makeWindow().controller
        let slider = try XCTUnwrap(controller.opacitySlider)

        XCTAssertEqual(slider.minValue, Double(WidgetBackgroundStore.minimumOpacity))
        slider.doubleValue = slider.minValue
        slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(controller.opacityLabel?.stringValue, "5%")
    }

    private func makeWindow() throws -> (
        controller: WidgetSettingsWindowController,
        lampSchemes: LampSchemeStore,
        backgroundStore: WidgetBackgroundStore
    ) {
        let preferences = try isolatedPreferences()
        let lampSchemes = LampSchemeStore(preferences: preferences)
        let backgroundStore = WidgetBackgroundStore(preferences: preferences)
        return (
            WidgetSettingsWindowController(backgroundStore: backgroundStore, lampSchemes: lampSchemes),
            lampSchemes,
            backgroundStore
        )
    }
}

/// The one seam every other test steps over: a scheme chosen in the window has to reach the
/// lamp on screen. Nothing tells the widget a preference has moved, which is the failure the
/// `WidgetSettingsStore.onChange` comment was written about — a setting that appears not to
/// work and then fixes itself minutes later.
@MainActor
final class LampSchemeReachesTheWidgetTests: XCTestCase {
    func testARecolouredPhaseRepaintsTheRowOnScreen() throws {
        let preferences = try isolatedPreferences()
        let controller = HUDPanelController(
            locator: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: HUDFrameStore(preferences: preferences),
            settings: WidgetSettingsStore(preferences: preferences)
        )
        controller.showWindow(nil)
        controller.render(
            WidgetState(
                sessions: [
                    testSession(index: 0, title: "one", phase: .executing, lastObservedAt: Date())
                ]
            )
        )
        XCTAssertEqual(
            Self.lamp(in: controller)?.paintedColor?.srgbHex,
            SessionPhase.executing.defaultLampStyle.color.srgbHex
        )

        var scheme = LampScheme()
        scheme.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .executing)
        controller.setLampScheme(scheme)

        XCTAssertEqual(Self.lamp(in: controller)?.paintedColor?.srgbHex, "#FF0000")
    }

    private static func lamp(in controller: HUDPanelController) -> SessionLampView? {
        guard let root = controller.window?.contentView else {
            return nil
        }
        root.layoutSubtreeIfNeeded()
        return firstLamp(in: root)
    }

    private static func firstLamp(in view: NSView) -> SessionLampView? {
        if let lamp = view as? SessionLampView {
            return lamp
        }
        for subview in view.subviews {
            if let lamp = firstLamp(in: subview) {
                return lamp
            }
        }
        return nil
    }
}
