import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The `Row layout` section of the settings window.
///
/// Operated the way the lamp section's tests operate theirs — set the control, send its
/// action, read the store back — so the whole section is checked without an application and
/// without a person looking at it.
@MainActor
final class RowLayoutSectionTests: XCTestCase {
    func testEveryPartGetsARowThatSaysWhenItAppears() throws {
        let (window, _) = try makeWindow()

        for part in RowPart.allCases where part != .gap {
            let box = try XCTUnwrap(window.partBoxes[part], "\(part) has no row")
            XCTAssertFalse(box.toolTip?.isEmpty ?? true, "\(part) does not say when it appears")
        }
    }

    /// Found by drawing the window: given the whole sentence, the column squeezed it to `Ir`
    /// and `C` — a column whose job is to warn that a part is rare, saying nothing at all.
    /// The width is stated in the grid now, and this keeps the wording inside it: the column
    /// holds about twenty characters at the row font, and the sentence stays in the tooltip.
    func testTheColumnBesideAPartSaysWhenItAppearsInWordsThatFit() {
        for part in RowPart.allCases {
            XCTAssertLessThanOrEqual(
                part.appearsWhenBriefly.count,
                20,
                "\(part) would be cut off in the column"
            )
            XCTAssertFalse(part.appearsWhen.isEmpty, "\(part) explains nothing on hover")
        }
    }

    func testUncheckingAPartTakesItOutOfTheTemplate() throws {
        let (window, rowLayouts) = try makeWindow()
        let context = try XCTUnwrap(window.partBoxes[.context])

        context.state = .off
        context.sendAction(context.action, to: context.target)

        XCTAssertFalse(rowLayouts.layout.shows(.context))
        XCTAssertTrue(rowLayouts.layout.shows(.name), "the row beside it is untouched")
    }

    /// Switched off one at a time, the parts run out: measured, a template of nothing but the
    /// gap draws a strip 33 points wide, and on the widget every row becomes that strip — a
    /// working session's empty, a finished one's a bare `×`. The way back is
    /// `Use the app's own row`, which puts back everything else too. So the last part in the
    /// row stays, greyed, and says why on hover.
    func testTheLastPartInTheRowCannotBeSwitchedOff() throws {
        let (window, rowLayouts) = try makeWindow()

        // The way a person empties it: pressing what can be pressed until nothing can.
        for part in RowPart.allCases where part != .gap {
            guard let box = window.partBoxes[part], box.isEnabled, box.state == .on else {
                continue
            }
            box.state = .off
            box.sendAction(box.action, to: box.target)
        }

        let left = rowLayouts.layout.parts.filter { $0 != .gap }
        XCTAssertEqual(left.count, 1, "the row was emptied down to its gap")
        let last = try XCTUnwrap(window.partBoxes[try XCTUnwrap(left.first)])
        XCTAssertFalse(last.isEnabled, "the last part in the row can still be switched off")
        XCTAssertEqual(last.state, .on, "and it is still drawn")
        XCTAssertNotEqual(
            last.toolTip, left.first?.appearsWhen,
            "greyed without saying why is half the answer"
        )
    }

    func testMovingAPartEarlierIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        let up = try XCTUnwrap(window.moveUpButtons[.lamp])

        up.sendAction(up.action, to: up.target)

        XCTAssertEqual(
            rowLayouts.layout.parts,
            [.lamp, .timer, .agent, .fault, .name, .gap, .counters, .context]
        )
    }

    /// The gap moves like anything else. It is the one part with no checkbox, because a row
    /// without it has no right edge — see ADR-0011.
    func testTheGapCanBeMovedButNotSwitchedOff() throws {
        let (window, rowLayouts) = try makeWindow()

        XCTAssertNil(window.partBoxes[.gap], "the gap offers no way to remove itself")

        let up = try XCTUnwrap(window.moveUpButtons[.gap])
        up.sendAction(up.action, to: up.target)

        XCTAssertEqual(rowLayouts.layout.parts.firstIndex(of: .gap), 4)
    }

    /// The parts left out of the row are listed after the ones in it, so the last part in the
    /// row has a part below it that it cannot trade places with: moving it down would put it
    /// among the ones not drawn, which is what its checkbox is for. A button that is offered
    /// and does nothing is worse than one that is greyed — see the disable-and-explain rule.
    func testTheLastPartInTheRowIsNotOfferedAWayDown() throws {
        let (window, rowLayouts) = try makeWindow()
        let last = try XCTUnwrap(rowLayouts.layout.parts.last)

        let down = try XCTUnwrap(window.moveDownButtons[last])

        XCTAssertFalse(down.isEnabled, "\(last) is last in the row and has nowhere to go")
    }

    /// And a part that is not in the row has neither arrow, for the same reason from the other
    /// side: there is no order to move it in. The parts left out are listed in the order this
    /// app names them, nothing stores an order for them, and nothing on the widget would
    /// change if it did. Found offered instead — eight of the ten arrows on the five parts
    /// left out were live, and pressing one changed nothing at all.
    func testAPartLeftOutOfTheRowIsOfferedNoArrowAtAll() throws {
        let (window, rowLayouts) = try makeWindow()
        let layout = rowLayouts.layout

        for part in RowPart.allCases where !layout.shows(part) {
            XCTAssertFalse(
                try XCTUnwrap(window.moveUpButtons[part]).isEnabled,
                "\(part) is not in the row and is offered a way up"
            )
            XCTAssertFalse(
                try XCTUnwrap(window.moveDownButtons[part]).isEnabled,
                "\(part) is not in the row and is offered a way down"
            )
        }
    }

    func testChoosingWhatTheNameShowsIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        let style = try XCTUnwrap(window.variantButtons[.name])

        style.selectItem(at: 1)
        style.sendAction(style.action, to: style.target)

        XCTAssertEqual(rowLayouts.layout.nameStyle, .title)
    }

    func testChoosingWhichPartGivesWayIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        let branchBox = try XCTUnwrap(window.partBoxes[.branch])
        branchBox.state = .on
        branchBox.sendAction(branchBox.action, to: branchBox.target)

        let givesWay = try XCTUnwrap(window.flexibleButtons[.branch])
        givesWay.sendAction(givesWay.action, to: givesWay.target)

        XCTAssertEqual(rowLayouts.layout.flexible, .branch)
    }

    /// The name is what gives way until somebody says otherwise, so the row it sits in has to
    /// offer the choice — with the radio shared with the variant list, the name had none, and
    /// a person who moved "gives way" to the branch could not move it back.
    func testEveryPartThatCanGiveWayIsOfferedTheChoice() throws {
        let (window, _) = try makeWindow()

        for part in RowPart.allCases where part.canGiveWay {
            XCTAssertNotNil(window.flexibleButtons[part], "\(part) can give way and cannot be chosen")
        }
        XCTAssertEqual(window.flexibleButtons[.name]?.state, .on, "and the one that does is on")
    }

    func testChoosingTheNameAsThePartThatGivesWayIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        let branch = try XCTUnwrap(window.partBoxes[.branch])
        branch.state = .on
        branch.sendAction(branch.action, to: branch.target)
        let toTheBranch = try XCTUnwrap(window.flexibleButtons[.branch])
        toTheBranch.sendAction(toTheBranch.action, to: toTheBranch.target)

        let backToTheName = try XCTUnwrap(window.flexibleButtons[.name])
        backToTheName.sendAction(backToTheName.action, to: backToTheName.target)

        XCTAssertEqual(rowLayouts.layout.flexible, .name)
    }

    // MARK: - Which kinds the counter block counts

    /// Six kinds in one menu rather than six rows of their own: they are one part of the row,
    /// they are chosen together, and six almost identical rows would bury the twelve parts.
    func testTheCounterBlockOffersEveryKindItCanCount() throws {
        let (window, _) = try makeWindow()

        for kind in ActivityKind.allCases {
            let item = try XCTUnwrap(window.counterKindItems[kind], "\(kind) cannot be chosen")
            XCTAssertEqual(item.state, .on, "everything is counted until something is switched off")
        }
    }

    func testSwitchingAKindOffIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        // Pressed the way a person presses it: the mark beside the item says it is counted,
        // and the press means "stop counting it". AppKit does not flip that mark itself.
        let shell = try XCTUnwrap(window.counterKindItems[.shell])

        press(shell)

        XCTAssertFalse(rowLayouts.layout.counterKinds.contains(.shell))
        XCTAssertTrue(rowLayouts.layout.counterKinds.contains(.tool), "the kind beside it is untouched")
    }

    /// Switching the last one off would leave a part that draws nothing and cannot say why —
    /// indistinguishable from a session with no work. The value repairs that to "count them
    /// all", and the menu has to show what was really stored rather than the empty choice.
    func testSwitchingEveryKindOffCountsThemAllAgain() throws {
        let (window, rowLayouts) = try makeWindow()

        for kind in ActivityKind.allCases {
            // Looked up again on every turn: each press rebuilds the menu, so the item from
            // the turn before belongs to a menu nobody can see any more.
            let item = try XCTUnwrap(window.counterKindItems[kind])
            press(item)
        }

        XCTAssertEqual(rowLayouts.layout.counterKinds, Set(ActivityKind.allCases))
        XCTAssertEqual(window.counterKindItems[.shell]?.state, .on)
    }

    /// The checkbox is about the row that has no `×` — a session still at work — so one sample
    /// row cannot show it at all. With two, the effect is the thing a person came to see: what
    /// the rows end with lines up, or it does not.
    func testTheSampleShowsWhatKeepingTheDismissColumnDoes() throws {
        let (window, _) = try makeWindow()
        let working = try XCTUnwrap(window.sampleWorkingRow)
        let finished = try XCTUnwrap(window.sampleRow)

        XCTAssertLessThan(working.fittingSize.width, finished.fittingSize.width)

        let keep = try XCTUnwrap(window.dismissColumnBox)
        keep.state = .on
        keep.sendAction(keep.action, to: keep.target)

        XCTAssertEqual(
            try XCTUnwrap(window.sampleWorkingRow).fittingSize.width,
            try XCTUnwrap(window.sampleRow).fittingSize.width,
            accuracy: 0.5,
            "the column is held open, so the two rows end in the same place"
        )
    }

    /// Two rows that differ by one character read as a duplicate: the first question the
    /// window was asked is why the row settings show the same row twice. The pair cannot go —
    /// it is the only way `Keep the × column` shows anything — so the caption says what the
    /// pair is, under the rows and above the list of parts, where it is read before the
    /// question is asked.
    func testTheSamplePairSaysWhatItsTwoRowsAre() throws {
        let (window, _) = try makeWindow()
        let caption = try XCTUnwrap(window.sampleCaption, "the pair explains nothing")
        XCTAssertTrue(
            caption.stringValue.contains("×"),
            "the caption does not name the one difference between the rows"
        )

        let root = try XCTUnwrap(window.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let finished = try XCTUnwrap(window.sampleRow)
        var topOfTheList = -CGFloat.greatestFiniteMagnitude
        for part in RowPart.allCases where part != .gap {
            let box = try XCTUnwrap(window.partBoxes[part])
            topOfTheList = max(topOfTheList, box.convert(box.bounds, to: nil).maxY)
        }

        let stands = caption.convert(caption.bounds, to: nil)
        XCTAssertLessThanOrEqual(
            stands.maxY,
            finished.convert(finished.bounds, to: nil).minY,
            "the caption does not stand under the pair it explains"
        )
        XCTAssertGreaterThanOrEqual(
            stands.minY, topOfTheList, "the caption has drifted into the list of parts")
    }

    func testKeepingTheDismissColumnIsStored() throws {
        let (window, rowLayouts) = try makeWindow()
        let keep = try XCTUnwrap(window.dismissColumnBox)

        keep.state = .on
        keep.sendAction(keep.action, to: keep.target)

        XCTAssertTrue(rowLayouts.layout.reservesDismissColumn)
    }

    /// The sample above the controls is a real row, built the same way the widget builds one,
    /// so what it shows is what the widget will show rather than a drawing of it.
    func testTheSampleRowIsRedrawnWhenTheTemplateChanges() throws {
        let (window, _) = try makeWindow()
        XCTAssertEqual(window.sampleRow?.drawnParts.contains(.context), true)

        let context = try XCTUnwrap(window.partBoxes[.context])
        context.state = .off
        context.sendAction(context.action, to: context.target)

        XCTAssertEqual(window.sampleRow?.drawnParts.contains(.context), false)
    }

    /// Reset is the way back for somebody who has taken the row apart, and the controls have
    /// to show the row it went back to — not the one they were left on.
    func testResetPutsTheTemplateAndItsControlsBack() throws {
        let (window, rowLayouts) = try makeWindow()
        let context = try XCTUnwrap(window.partBoxes[.context])
        context.state = .off
        context.sendAction(context.action, to: context.target)

        window.resetRowLayout()

        XCTAssertEqual(rowLayouts.layout, .standard)
        XCTAssertEqual(window.partBoxes[.context]?.state, .on)
    }

    /// The sample is drawn on the widget's own background, so choosing another one has to
    /// redraw it. Otherwise the window shows a row on a background the widget no longer has —
    /// and the whole reason the sample is a real row is that it does not lie about the widget.
    func testChoosingAnotherBackgroundRedrawsTheSample() throws {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let backgroundStore = WidgetBackgroundStore(preferences: preferences)
        let window = WidgetSettingsWindowController(
            backgroundStore: backgroundStore,
            lampSchemes: LampSchemeStore(preferences: preferences),
            settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings)
        )
        let mint = try XCTUnwrap(window.backgroundButtons[.mint])

        mint.performClick(nil)

        XCTAssertEqual(window.sampleRow?.background, .mint)
    }

    /// Found in the running window, which had three copies of the whole section stacked on
    /// top of each other: `NSGridView.removeRow(at:)` takes the row out of the grid and
    /// leaves its views where they were, so the grid stopped counting them while the window
    /// went on drawing them. Identical copies only look thick; once a part had been moved,
    /// the old order and the new one were drawn one over the other.
    func testAPartHasOneControlInTheWindowHoweverOftenTheListIsRebuilt() throws {
        let (window, _) = try makeWindow()
        let root = try XCTUnwrap(window.window?.contentView)

        // One click, which is all a person needs to do: every change rebuilds the list.
        let context = try XCTUnwrap(window.partBoxes[.context])
        context.state = .off
        context.sendAction(context.action, to: context.target)

        for part in RowPart.allCases where part != .gap {
            XCTAssertEqual(
                Self.checkboxes(titled: part.settingsName, in: root).count,
                1,
                "\(part) stands in the window more than once"
            )
        }
    }

    /// Every checkbox with this title anywhere in the window, which is the only way to see
    /// the copies: the controller's own dictionaries hold the newest one alone. Pop-up
    /// buttons are left out — one of them wears the title `Name` because that is the variant
    /// the model part is showing, and it is not a second `Name` row.
    private static func checkboxes(titled title: String, in view: NSView) -> [NSButton] {
        let here = [view]
            .compactMap { $0 as? NSButton }
            .filter { $0.title == title && !($0 is NSPopUpButton) }
        return here + view.subviews.flatMap { checkboxes(titled: title, in: $0) }
    }

    /// A menu item has no `sendAction` of its own — the menu sends it. Pressed the way
    /// AppKit presses it: the action, to the target, from the item.
    private func press(_ item: NSMenuItem) {
        guard let action = item.action else {
            return XCTFail("\(item.title) does nothing")
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func makeWindow() throws -> (WidgetSettingsWindowController, RowLayoutStore) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let rowLayouts = RowLayoutStore(preferences: preferences)
        let window = WidgetSettingsWindowController(
            backgroundStore: WidgetBackgroundStore(preferences: preferences),
            lampSchemes: LampSchemeStore(preferences: preferences),
            settings: settings,
            rowLayouts: rowLayouts,
            shortcuts: FakeShortcutRegistrar.controller(for: settings)
        )
        return (window, rowLayouts)
    }
}
