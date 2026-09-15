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
        let (controller, lampSchemes, _, _) = try makeWindow()
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
        let (controller, lampSchemes, _, _) = try makeWindow()
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

        let settings = WidgetSettingsStore(preferences: preferences)
        let controller = WidgetSettingsWindowController(
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: lampSchemes,
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings)
        )

        XCTAssertEqual(
            controller.motionButtons[.idle]?.titleOfSelectedItem,
            SessionLampAppearance.Motion.urgent.title
        )
        XCTAssertEqual(controller.colorWells[.idle]?.color.srgbHex, "#FF0000")
    }

    func testResetPutsEveryRowBackToTheAppsOwnLamp() throws {
        let (controller, lampSchemes, _, _) = try makeWindow()
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
        let (controller, _, backgroundStore, _) = try makeWindow()
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

    /// The size slider is the preview: the widget is on screen while the window is open, so
    /// the number it reports has to be the number the store holds after the drag.
    func testTheSizeSliderSnapsToTheSizesOnOffer() throws {
        let (controller, _, _, settings) = try makeWindow()
        let slider = try XCTUnwrap(controller.scaleSlider)

        XCTAssertEqual(slider.numberOfTickMarks, WidgetSettingsStore.offeredScales.count)
        XCTAssertTrue(slider.allowsTickMarkValuesOnly, "a free slider offers sizes nobody can tell apart")
        // Each stop, not just how many there are: AppKit spaces tick marks evenly between the
        // ends, so the sizes on offer have to be evenly spaced too. One uneven step added to
        // the list and the slider would quietly hand back sizes that are not on it.
        for (index, scale) in WidgetSettingsStore.offeredScales.enumerated() {
            XCTAssertEqual(
                slider.tickMarkValue(at: index),
                Double(scale),
                accuracy: 0.001,
                "tick \(index) is not the size the list offers there"
            )
        }
        XCTAssertEqual(controller.scaleLabel?.stringValue, "100%", "it opens at the size in force")

        slider.doubleValue = slider.maxValue
        slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(settings.scale, WidgetSettingsStore.maximumScale)
        XCTAssertEqual(controller.scaleLabel?.stringValue, "200%")
    }

    func testTheWindowShowsTheCombinationTheWidgetAnswersTo() throws {
        let (controller, _, _, _) = try makeWindow()

        XCTAssertEqual(controller.shortcutRecorder?.title, "⌥⌘W")
    }

    func testACombinationRecordedInTheWindowIsKept() throws {
        let (controller, _, _, settings) = try makeWindow()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)

        recorder.startRecording()
        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))

        XCTAssertEqual(settings.toggleShortcut?.displayed, "⌃⇧F5")
        XCTAssertEqual(recorder.title, "⌃⇧F5")
    }

    func testClearingLeavesTheWidgetWithNoCombinationAtAll() throws {
        let (controller, _, _, settings) = try makeWindow()
        let clear = try XCTUnwrap(controller.shortcutClearButton)

        clear.sendAction(clear.action, to: clear.target)

        XCTAssertNil(settings.toggleShortcut)
        XCTAssertEqual(controller.shortcutRecorder?.title, shortcutEmptyButton)
    }

    /// The control that cannot do its job stays where it is and says why — hiding it would
    /// leave the person with a widget that ignores the combination they can still see set.
    func testARegistrationThatDidNotTakeIsExplainedRatherThanHidden() throws {
        let (controller, _, _, _) = try makeWindow(answer: .alreadyOurs)

        XCTAssertEqual(
            controller.shortcutStatusLabel?.stringValue,
            shortcutStatusLine(.alreadyOurs(try optionCommandW()))
        )
        XCTAssertTrue(controller.shortcutRecorder?.isEnabled == true, "the way out is to record another")
    }

    func testAPressThatCannotBeAShortcutSaysWhatWouldBeAccepted() throws {
        let (controller, _, _, _) = try makeWindow()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)

        recorder.startRecording()
        recorder.keyDown(with: try press(keyCode: 13, flags: []))

        XCTAssertEqual(controller.shortcutStatusLabel?.stringValue, shortcutAcceptedKeys)
    }

    /// The old combination is still registered while a new one is being chosen. Left live, it
    /// would hide the widget out from under the person in the middle of choosing — and the
    /// press that did it would also be the press they were trying to record.
    func testTheOldCombinationGoesQuietWhileANewOneIsBeingChosen() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)

        recorder.sendAction(recorder.action, to: recorder.target)

        XCTAssertTrue(shortcuts.isMuted)
    }

    func testTheCombinationSpeaksAgainOnceTheChoosingIsOver() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        recorder.sendAction(recorder.action, to: recorder.target)

        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))

        XCTAssertFalse(shortcuts.isMuted)
    }

    /// A press it will not take leaves the recorder waiting for another, so the quiet has to
    /// last exactly as long as that wait — not until the first press, whatever it was.
    func testTheCombinationStaysQuietWhileTheRecorderIsStillWaiting() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        recorder.sendAction(recorder.action, to: recorder.target)

        recorder.keyDown(with: try press(keyCode: 13, flags: []))

        XCTAssertTrue(shortcuts.isMuted)
    }

    /// A person who starts recording and then changes their mind presses nothing, so nothing
    /// reports anything — and the quiet that was meant to last as long as the choosing lasted
    /// outlived the window. The combination stayed registered and printed beside the menu
    /// line, and pressing it did nothing at all until the next visit to this window.
    func testWalkingAwayFromTheRecorderLetsTheCombinationSpeakAgain() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        recorder.sendAction(recorder.action, to: recorder.target)
        XCTAssertTrue(shortcuts.isMuted, "the old combination goes quiet while a new one is chosen")

        try XCTUnwrap(controller.window).makeFirstResponder(nil)

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertEqual(recorder.title, "⌥⌘W", "and the button stops asking for a press")
    }

    /// The same change of mind, made by closing the window rather than by clicking past the
    /// recorder. Worth its own test because the way out is a different one: AppKit does not
    /// promise that closing a window takes the focus off the control inside it.
    func testClosingTheWindowMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        controller.present()
        recorder.sendAction(recorder.action, to: recorder.target)
        XCTAssertTrue(shortcuts.isMuted)

        controller.close()

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertFalse(recorder.isRecording)
    }

    /// And the third way out: leaving for another application without touching this window at
    /// all. Recoverable, unlike the other two — the person can come back and press a key — but
    /// until they do, the shortcut is registered and silent, which is the state this whole
    /// group of tests exists to forbid.
    func testLeavingForAnotherApplicationMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        controller.present()
        recorder.sendAction(recorder.action, to: recorder.target)
        XCTAssertTrue(shortcuts.isMuted)

        try XCTUnwrap(controller.window).resignKey()

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertFalse(recorder.isRecording)
    }

    /// The window measures itself once, at construction, from the text the status line happens
    /// to hold then. Every other sentence it can show has to fit in that same room — the longest
    /// is the one about which keys are accepted, and it is three times the length of the one the
    /// window opens with.
    func testTheStatusLineHasRoomForTheLongestThingItCanSay() throws {
        let (controller, _, _, _) = try makeWindow()
        let label = try XCTUnwrap(controller.shortcutStatusLabel)
        let shortcut = try optionCommandW()
        try XCTUnwrap(controller.window?.contentView).layoutSubtreeIfNeeded()
        let room = label.frame.height

        for line in [
            shortcutAcceptedKeys,
            shortcutStatusLine(.none),
            shortcutStatusLine(.active(shortcut)),
            shortcutStatusLine(.alreadyOurs(shortcut)),
            shortcutStatusLine(.refused(shortcut, code: -9878)),
        ] {
            label.stringValue = line
            let needed = label.sizeThatFits(
                NSSize(width: label.frame.width, height: .greatestFiniteMagnitude)
            ).height
            XCTAssertLessThanOrEqual(needed, room, "no room for: \(line)")
        }
    }

    /// For the tests that are about the shortcut itself rather than about the window: the window
    /// does not hand its collaborators back, and it should not have to grow a way to just for a
    /// test.
    private func makeWindowKeepingItsShortcuts() throws -> (
        WidgetSettingsWindowController, WidgetShortcutController
    ) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let shortcuts = FakeShortcutRegistrar.controller(for: settings)
        let window = WidgetSettingsWindowController(
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: LampSchemeStore(preferences: preferences),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: shortcuts
        )
        return (window, shortcuts)
    }

    private func makeWindow(
        answer: ShortcutRegistrationOutcome = .registered
    ) throws -> (
        controller: WidgetSettingsWindowController,
        lampSchemes: LampSchemeStore,
        backgroundStore: WidgetBackgroundStore,
        settings: WidgetSettingsStore
    ) {
        let preferences = try isolatedPreferences()
        let lampSchemes = LampSchemeStore(preferences: preferences)
        let backgroundStore = WidgetBackgroundStore(preferences: preferences)
        let settings = WidgetSettingsStore(preferences: preferences)
        let registrar = FakeShortcutRegistrar()
        registrar.answer = answer
        let shortcuts = WidgetShortcutController(
            settings: settings,
            registrar: registrar,
            onToggle: {}
        )
        shortcuts.apply()
        return (
            WidgetSettingsWindowController(
                backgroundStore: backgroundStore,
                lampSchemes: lampSchemes,
                settings: settings,
                rowLayouts: RowLayoutStore(preferences: preferences),
                shortcuts: shortcuts
            ),
            lampSchemes,
            backgroundStore,
            settings
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
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: HUDFrameStore(preferences: preferences),
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: RowLayoutStore(preferences: preferences)
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

    /// The size chosen in the window has to redraw the widget while the person is still
    /// holding the slider — the whole reason the control is a slider and not a menu.
    ///
    /// Through the store's own `onChange`, the way the running app is wired, rather than by
    /// calling the controller: the seam this test exists for is the one between a preference
    /// being written and the widget hearing about it.
    func testEnlargingTheWidgetRedrawsTheRowsAtOnce() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            style: WidgetStyle(scale: settings.scale),
            frameStore: HUDFrameStore(preferences: preferences),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        settings.onChange = { setting in
            guard case .scale = setting else {
                return
            }
            controller.setScale(settings.scale)
        }
        controller.showWindow(nil)
        // Wide enough that the new size's floor cannot move it. A widget that grows to meet
        // the floor changes its own width, and the list is rebuilt for a width change on its
        // own — which would let this pass with the scale never compared at all.
        try XCTUnwrap(controller.window).setContentSize(NSSize(width: 600, height: 400))
        controller.render(
            WidgetState(
                sessions: [
                    testSession(index: 0, title: "one", phase: .executing, lastObservedAt: Date())
                ]
            )
        )
        let widthBefore = try XCTUnwrap(controller.window).frame.width
        let before = try XCTUnwrap(controller.visibleRows.first)
        before.layoutSubtreeIfNeeded()
        let beforeHeight = before.frame.height

        settings.setScale(2)

        let after = try XCTUnwrap(controller.visibleRows.first)
        after.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            try XCTUnwrap(controller.window).frame.width,
            widthBefore,
            "the widget did not change width, so only the scale can have rebuilt the row"
        )
        XCTAssertFalse(after === before, "the row on screen is the old one, drawn at its old size")
        XCTAssertGreaterThan(after.frame.height, beforeHeight)
        XCTAssertEqual(after.frame.height, WidgetStyle(scale: 2).rowHeight, accuracy: 0.5)
    }

    /// A widget parked at its smallest is below the floor the moment the scale grows, and
    /// macOS does not grow a window to meet a minimum it has just been handed — so the rows
    /// would be laid out inside a window too short to show them.
    func testTheWidgetGrowsPastTheFloorItUsedToSitOn() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let frameStore = HUDFrameStore(preferences: preferences)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.showWindow(nil)
        let panel = try XCTUnwrap(controller.window)
        panel.setContentSize(WidgetStyle.standard.minimumWindowSize)

        controller.setScale(2)

        let floor = WidgetStyle(scale: 2).minimumWindowSize
        XCTAssertEqual(panel.minSize, floor, "the widget may still be dragged smaller than it draws")
        XCTAssertGreaterThanOrEqual(panel.frame.height, floor.height)
        XCTAssertGreaterThanOrEqual(panel.frame.width, floor.width)
        // Growing to meet the new floor is the app's doing, not a size the person chose, and
        // remembering it as one would quietly end the widget's habit of sizing itself to the
        // number of sessions — which is how a fresh install behaves.
        XCTAssertTrue(
            frameStore.sizeFollowsSessions,
            "changing the size turned off the widget sizing itself to its sessions"
        )
    }

    /// The window and the preferences file both clamp the size, and they have to agree. A
    /// size the window allows and the file rounds up is a widget that springs back to a size
    /// nobody chose on the next launch — which is what going below the tuned size opened up,
    /// since until then the window's floor was never the lower of the two.
    func testTheSavedSizeIsHeldToTheSameFloorTheWindowIs() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let frameStore = HUDFrameStore(preferences: preferences)
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.showWindow(nil)
        let panel = try XCTUnwrap(controller.window)

        controller.setScale(WidgetSettingsStore.minimumScale)

        let floor = WidgetStyle(scale: WidgetSettingsStore.minimumScale).minimumWindowSize
        XCTAssertEqual(panel.minSize, floor)
        // Dragged to the smallest the window now allows, and saved: what comes back has to be
        // that size, not the size the tuned scale's floor would have rounded it up to.
        frameStore.save(floor)
        XCTAssertEqual(frameStore.size, floor)
    }

    /// And that floor has to be in force before the widget is built, not from its first
    /// refresh. The window is created from the size on file, so a store still holding the
    /// tuned size's floor rounds a smaller saved size up before anything has said otherwise —
    /// and the widget opens larger than the person left it, with nothing afterwards to put it
    /// back: a size that was chosen is never recomputed.
    func testAWidgetLeftBelowTheTunedFloorOpensAtTheSizeItWasLeftAt() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        settings.setScale(WidgetSettingsStore.minimumScale)
        let smallest = WidgetStyle(scale: settings.scale).minimumWindowSize

        // Dragged to the smallest the window allows at this size, in the session before.
        let saving = HUDFrameStore(preferences: preferences)
        saving.minimumSize = smallest
        saving.save(smallest)

        // A fresh launch: new stores, and the style built from the scale on file.
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            style: WidgetStyle(scale: settings.scale),
            frameStore: HUDFrameStore(preferences: preferences),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.showWindow(nil)
        let panel = try XCTUnwrap(controller.window)

        XCTAssertEqual(
            panel.frame.size,
            smallest,
            "the widget opened at the tuned size's floor instead of the size it was left at"
        )
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
