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

    /// And the first part left out has nowhere up, for the same reason from the other side.
    func testTheFirstPartLeftOutIsNotOfferedAWayUp() throws {
        let (window, rowLayouts) = try makeWindow()
        let layout = rowLayouts.layout
        let firstLeftOut = try XCTUnwrap(RowPart.allCases.first { !layout.shows($0) })

        let up = try XCTUnwrap(window.moveUpButtons[firstLeftOut])

        XCTAssertFalse(up.isEnabled, "\(firstLeftOut) is not in the row, so there is no order to move it in")
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

        XCTAssertEqual(window.sampleRow?.drawnOn, .mint)
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
