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

    /// A press on the well is a choice, like a press on a swatch, and it opens the panel on the
    /// wheel whatever page the panel was last left at.
    ///
    /// A mouse event sent to the window rather than `activate` called, and that is the point.
    /// The trap here is a well made with `init(style:)`, which is a plain `NSColorWell` under a
    /// subclass's name: a click reaches AppKit's own `activate` and chooses nothing. Called from
    /// Swift, `activate(true)` ran the override anyway — the class is `final`, so the call never
    /// asked the object what it really is — and this test passed with the trap in place, which
    /// is how it came to click.
    func testTheCustomWellChoosesItsColourAndOpensTheWheel() throws {
        let (controller, _, backgroundStore, _) = try makeWindow()
        controller.showWindow(nil)
        try show(tab: "Other", of: controller)
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let well = try XCTUnwrap(controller.customBackgroundWell)
        defer {
            well.deactivate()
            NSColorPanel.shared.orderOut(nil)
            controller.close()
        }
        NSColorPanel.shared.mode = .RGB

        try click(well, in: window)

        XCTAssertTrue(well.isActive, "the click did not reach the well")
        XCTAssertEqual(NSColorPanel.shared.mode, .wheel)
        XCTAssertTrue(backgroundStore.selected.isCustom)
        XCTAssertEqual(
            backgroundStore.selected.color.srgbHex,
            WidgetBackground.graphite.color.srgbHex,
            "before the wheel is touched the widget keeps the colour it had"
        )
    }

    /// The ring is the only thing that says which background is in use, so it has to leave the
    /// swatches for the well and come back.
    func testTheRingMovesBetweenTheSwatchesAndTheWell() throws {
        let (controller, _, backgroundStore, _) = try makeWindow()
        let well = try XCTUnwrap(controller.customBackgroundWell)
        let ring = try XCTUnwrap(controller.customBackgroundRing)
        let clear = NSColor.clear.cgColor

        well.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        well.sendAction(well.action, to: well.target)

        XCTAssertEqual(backgroundStore.selected.color.srgbHex, "#336699")
        XCTAssertTrue(controller.backgroundButtons.values.allSatisfy { $0.state == .off })
        // The accent itself, not merely "not clear": a layer's border is black until it is
        // told otherwise, so a ring nobody set would pass that.
        XCTAssertEqual(ring.layer?.borderColor, NSColor.controlAccentColor.cgColor)

        try XCTUnwrap(controller.backgroundButtons[.mint]).performClick(nil)

        XCTAssertEqual(ring.layer?.borderColor, clear)
        XCTAssertEqual(
            well.color.srgbHex,
            "#336699",
            "the well goes on offering the colour after a preset is chosen"
        )
    }

    /// Before anybody has picked a colour, the wheel opens on the background in use rather than
    /// on some colour the widget has never been.
    func testTheWellStartsFromTheBackgroundInUse() throws {
        let (controller, _, backgroundStore, _) = try makeWindow()
        try XCTUnwrap(controller.backgroundButtons[.sand]).performClick(nil)

        XCTAssertNil(backgroundStore.customColor)
        XCTAssertEqual(controller.customBackgroundWell?.color.srgbHex, WidgetBackground.sand.color.srgbHex)
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

    /// And the way out the tabs added: the recorder is taken out of the window when another
    /// tab comes up, which is a change of mind like walking away from it. Without this the
    /// combination would stay muted with the control that muted it no longer on screen.
    func testLeavingTheTabMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (controller, shortcuts) = try makeWindowKeepingItsShortcuts()
        let recorder = try XCTUnwrap(controller.shortcutRecorder)
        recorder.sendAction(recorder.action, to: recorder.target)
        XCTAssertTrue(shortcuts.isMuted, "the old combination goes quiet while a new one is chosen")

        try show(tab: "Row", of: controller)

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

    // MARK: - The window against the screen it opens on

    /// Measured, not reasoned about: the window opened 1290 points tall on a screen with 1079
    /// to give, was not resizable and had no scroller — so `Size` and `Shortcut` sat below the
    /// bottom edge with no way to reach them. The cap and the scroller come together: a window
    /// that stops at the screen is only honest if what is past the cap can still be scrolled to.
    func testTheWindowIsNoTallerThanTheScreenLeavesRoomFor() throws {
        let controller = try makeWindow().controller
        let window = try XCTUnwrap(controller.window)

        // The screen itself rather than the cap: the cap is the mechanism, and what has to
        // hold is that the window opens inside the room the screen has.
        XCTAssertLessThanOrEqual(
            window.frame.height,
            NSScreen.main?.visibleFrame.height ?? 900
        )
    }

    func testWhatThatCapCutsOffCanStillBeScrolledTo() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)

        for item in tabs.tabViewItems {
            let scroll = try XCTUnwrap(
                item.view as? NSScrollView,
                "\(item.label) is capped by the screen, so it has to scroll"
            )
            XCTAssertTrue(scroll.hasVerticalScroller, "\(item.label) has no scroller")
            XCTAssertNotNil(scroll.documentView, "\(item.label) holds nothing")
        }
    }

    /// What the tabs are for. Before them the window was one column of six sections, so it
    /// asked for the height of all of them at once — 1290 points, capped at the screen and
    /// scrolled for the rest. A tab is shown on its own, so the window only ever has to be as
    /// tall as the tallest one.
    func testTheWindowIsNoTallerThanTheTabThatNeedsTheMostRoom() throws {
        let controller = try makeWindow().controller
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentView as? NSTabView)
        let chrome = tabs.bounds.height - tabs.contentRect.height

        let tallest =
            try tabs.tabViewItems
            .map { try XCTUnwrap(($0.view as? NSScrollView)?.documentView).fittingSize.height }
            .max() ?? 0

        // Both ways round: taller and the window carries dead space under whichever tab is
        // showing, shorter and the tab it opens on scrolls for no reason.
        XCTAssertEqual(
            try XCTUnwrap(window.contentView).frame.height,
            min(tallest + chrome, WidgetSettingsWindowController.tallestUsefulWindow),
            accuracy: 1,
            "the window is not the height of the tab that needs the most room"
        )
    }

    /// The size slider is as wide as the tab it stands in, and grows with the window.
    ///
    /// Not a matter of taste: the slider carries one tick mark per size on offer, and at the
    /// 260 points it used to be fixed at, thirty-one of them draw as a picket fence. The room
    /// to spread them is the width the window already has for the parts grid.
    ///
    /// Checked at two widths, because a fixed width passes the first assertion on its own —
    /// 260 points is most of a narrow window — and only a slider that follows the window
    /// passes the second.
    func testTheSizeSliderIsAsWideAsTheTab() throws {
        let controller = try makeWindow().controller
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentView as? NSTabView)
        let scroll = try XCTUnwrap(tabs.tabViewItems.first?.view as? NSScrollView)
        tabs.selectTabViewItem(at: 0)
        tabs.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(controller.scaleSlider)
        let document = try XCTUnwrap(scroll.documentView)

        // The readout, the gap before it and the tab's two margins are all that may be left
        // over: 44 + 8 + 20 + 20, and a point of slack for rounding.
        XCTAssertGreaterThan(
            slider.frame.width,
            document.frame.width - 93,
            "the size slider does not reach across the tab"
        )

        let grown = window.frame.width + 200
        window.setContentSize(NSSize(width: grown, height: window.frame.height))
        tabs.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            slider.frame.width,
            document.frame.width - 93,
            "the size slider kept its width when the window grew"
        )
    }

    /// A tab with less in it than the window is tall still starts at the top. Without this
    /// the lamp and the rest hung from the bottom edge: an unflipped document view is
    /// anchored at its bottom-left corner, so a scroll view shorter than its window puts the
    /// content at the bottom and leaves the empty half above it.
    func testEveryTabStartsAtTheTopOfTheWindow() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)

        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            tabs.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(item.view as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)

            // In the window's own coordinates, so the answer does not depend on which of
            // these views is flipped: `maxY` there is the top edge on screen either way.
            XCTAssertEqual(
                document.convert(document.bounds, to: nil).maxY,
                scroll.contentView.convert(scroll.contentView.bounds, to: nil).maxY,
                accuracy: 1,
                "\(item.label) hangs from the bottom of the window"
            )
        }
    }

    /// A tab narrower than its own controls keeps the width they need and lets the rest be
    /// scrolled to, rather than being squeezed into the window.
    ///
    /// Squeezed, something has to give, and what gave was the parts grid: AppKit resolves an
    /// impossible set of constraints by breaking one of them and printing the whole set —
    /// which is the `Conflicting constraints detected` wall in Xcode's console. The window is
    /// born 400 points wide and measures its tabs only afterwards, so it passes through
    /// exactly this state every time it is built.
    ///
    /// Held to the narrow width by a constraint rather than by a frame: a window or a view
    /// given a frame too small for its content simply grows back, and then the scene proves
    /// nothing.
    func testATabTooNarrowIsScrolledToRatherThanSqueezed() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)
        let row = try XCTUnwrap(tabs.tabViewItems.first)
        let scroll = try XCTUnwrap(row.view as? NSScrollView)
        // Off the top and out of the tab view's hands, which hand the frame back otherwise.
        tabs.selectTabViewItem(at: 1)
        scroll.removeFromSuperview()

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
        host.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 380),
            scroll.heightAnchor.constraint(equalToConstant: 500),
        ])
        host.layoutSubtreeIfNeeded()

        let parts = try XCTUnwrap(Self.grid(in: try XCTUnwrap(scroll.documentView)))
        XCTAssertGreaterThanOrEqual(
            parts.frame.width,
            parts.fittingSize.width - 1,
            "the parts grid was squeezed, so one of its column widths had to be broken"
        )
    }

    private static func grid(in view: NSView) -> NSGridView? {
        if let found = view as? NSGridView {
            return found
        }
        return view.subviews.lazy.compactMap { grid(in: $0) }.first
    }

    func testTheSettingsStandInThreeTabs() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)

        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["Row", "Lamp", "Other"])
        XCTAssertEqual(
            tabs.selectedTabViewItem?.label,
            "Row",
            "the row is what a person came here for"
        )
    }

    /// Which tab each setting is under. The size belongs with the row rather than with the
    /// background because it is the row it makes larger — the widget has no size of its own
    /// beyond the rows in it.
    func testEverySettingStandsUnderTheTabItBelongsTo() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)

        func holds(_ label: String, _ control: NSView?) throws -> Bool {
            let item = try XCTUnwrap(tabs.tabViewItems.first { $0.label == label })
            let wanted = try XCTUnwrap(control)
            return Self.descendants(of: try XCTUnwrap(item.view)).contains { $0 === wanted }
        }

        XCTAssertTrue(try holds("Row", controller.partBoxes[.name]), "the parts are not in Row")
        XCTAssertTrue(try holds("Row", controller.scaleSlider), "the size is not in Row")
        XCTAssertTrue(
            try holds("Lamp", controller.colorWells[.executing]), "the colours are not in Lamp")
        XCTAssertTrue(
            try holds("Other", controller.backgroundButtons[.graphite]),
            "the background is not in Other"
        )
        XCTAssertTrue(try holds("Other", controller.opacitySlider), "the opacity is not in Other")
        XCTAssertTrue(
            try holds("Other", controller.shortcutRecorder), "the shortcut is not in Other")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// The other half of the same measurement: the window came up 492 points wide around
    /// content that wanted 512, because its size was taken before `showCurrentValues` filled
    /// the row layout's grid in. The section then lost its left margin and its last column ran
    /// past the right edge.
    func testTheWindowIsWideEnoughForEveryControlInIt() throws {
        let controller = try makeWindow().controller
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)

        for item in tabs.tabViewItems {
            // Each tab in turn, and shown: a tab view lays out the one on top and leaves the
            // others at whatever size they were born with.
            tabs.selectTabViewItem(item)
            let scroll = try XCTUnwrap(item.view as? NSScrollView)
            // The worst case on purpose, and the one this machine does not have: with "Always
            // show scroll bars" the scroller is a solid strip taking width out of the content
            // rather than an overlay taking none.
            scroll.scrollerStyle = .legacy
            let document = try XCTUnwrap(scroll.documentView)
            tabs.layoutSubtreeIfNeeded()

            XCTAssertGreaterThanOrEqual(
                document.frame.width,
                document.fittingSize.width,
                "\(item.label) is narrower than its own controls, and something is cut off"
            )
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
        // Shown, because recording needs the keyboard focus and a tab that is not on top is
        // not in the window at all — its controls cannot be focused, which is how a person
        // reaches them too.
        try show(tab: "Other", of: window)
        return (window, shortcuts)
    }

    /// A press and a release, the release queued first: a control tracks the mouse from its
    /// `mouseDown` until a release arrives, so one that was not already waiting would be waited
    /// for forever. Sent to this window, not posted to the system — it cannot land anywhere else.
    private func click(_ view: NSView, in window: NSWindow) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: time,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
        }
        NSApp.postEvent(try event(.leftMouseUp, at: now + 0.05), atStart: false)
        window.sendEvent(try event(.leftMouseDown, at: now))
    }

    private func show(tab label: String, of controller: WidgetSettingsWindowController) throws {
        let tabs = try XCTUnwrap(controller.window?.contentView as? NSTabView)
        tabs.selectTabViewItem(try XCTUnwrap(tabs.tabViewItems.first { $0.label == label }))
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
    /// A person dragging the size slider is looking at the slider, and the thing that
    /// changes is a small window somewhere else on the screen — possibly behind something,
    /// possibly one they have lost track of. So a change of size says where the widget is,
    /// with the outline the `Highlight Widget` menu line already draws: one language for
    /// "here it is", not a second one invented for this.
    func testChangingTheSizeSaysWhereTheWidgetIs() throws {
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
        defer { controller.shutdown() }
        controller.showWindow(nil)
        let panel = try XCTUnwrap(controller.window as? HUDPanel)
        // A real size: the outline is laid out against the content, and against nothing it
        // waits for geometry rather than drawing.
        panel.setContentSize(NSSize(width: 600, height: 400))
        XCTAssertNil(Self.outline(in: panel), "the widget is lit before anything happened")

        controller.setScale(2)

        XCTAssertNotNil(
            Self.outline(in: panel),
            "the widget changed size without saying which window it was"
        )
    }

    /// The two menu lines that move the widget without the person touching it. Both are
    /// pressed from the status menu, with the widget wherever it was — behind something, or on
    /// a screen the person is not looking at — and both answer a question that starts "where".
    /// `Reset Widget Position` especially: it is pressed by somebody who has lost the widget,
    /// and the middle of the main screen is still a place they have to find.
    func testPuttingTheSizeBackSaysWhereTheWidgetIs() throws {
        let (controller, panel) = try makeWidget()
        defer { controller.shutdown() }

        controller.resetSize()

        XCTAssertNotNil(
            Self.outline(in: panel),
            "the widget changed size without saying which window it was"
        )
    }

    func testPuttingThePositionBackSaysWhereTheWidgetIs() throws {
        let (controller, panel) = try makeWidget()
        defer { controller.shutdown() }

        controller.resetPosition()

        XCTAssertNotNil(
            Self.outline(in: panel),
            "the widget moved without saying which window it was"
        )
    }

    /// A widget on screen at a real size, and nothing lit yet. The size matters: the outline is
    /// laid out against the content, and against nothing it waits for geometry rather than
    /// drawing.
    private func makeWidget() throws -> (HUDPanelController, HUDPanel) {
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
        controller.showWindow(nil)
        let panel = try XCTUnwrap(controller.window as? HUDPanel)
        panel.setContentSize(NSSize(width: 600, height: 400))
        XCTAssertNil(Self.outline(in: panel), "the widget is lit before anything happened")
        return (controller, panel)
    }

    private static func outline(in panel: HUDPanel) -> HUDHighlightOverlayView? {
        panel.contentView?.subviews.compactMap { $0 as? HUDHighlightOverlayView }.last
    }

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
