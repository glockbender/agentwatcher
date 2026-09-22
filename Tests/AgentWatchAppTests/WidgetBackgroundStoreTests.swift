import Foundation
import XCTest

@testable import AgentWatchApp

final class WidgetBackgroundStoreTests: XCTestCase {
    func testUsesGraphiteWhenNoPreferenceWasSaved() throws {
        let preferences = try isolatedPreferences()

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).selected, .graphite)
    }

    func testPersistsTheSelectedBackground() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetBackgroundStore(preferences: preferences)

        store.select(.mint)

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).selected, .mint)
    }

    func testUsesTheExistingBackgroundOpacityByDefault() throws {
        let preferences = try isolatedPreferences()

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).opacity, 0.96)
    }

    func testPersistsTheSelectedBackgroundOpacity() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetBackgroundStore(preferences: preferences)

        store.selectOpacity(0.64)

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).opacity, 0.64)
    }

    func testClampsBackgroundOpacityToTheReadableRange() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetBackgroundStore(preferences: preferences)

        store.selectOpacity(-1)
        XCTAssertEqual(store.opacity, WidgetBackgroundStore.minimumOpacity)
        // The floor itself is the point: at zero the widget becomes invisible and the
        // person who made it invisible cannot find it again.
        XCTAssertGreaterThan(WidgetBackgroundStore.minimumOpacity, 0)
        XCTAssertLessThan(WidgetBackgroundStore.minimumOpacity, 0.2, "the old floor was too high to read as glass")

        store.selectOpacity(2)
        XCTAssertEqual(store.opacity, 1)
    }

    func testLightBackgroundsUseDarkTextIndependentOfSystemAppearance() {
        let expectedForeground = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        let expectedSecondary = NSColor(calibratedRed: 0.29, green: 0.33, blue: 0.38, alpha: 1)

        for background in WidgetBackground.light {
            XCTAssertEqual(background.foregroundColor, expectedForeground)
            XCTAssertEqual(background.secondaryForegroundColor, expectedSecondary)
        }
    }

    /// The other half of the rule the light presets are held to: a colour's own brightness
    /// decides its text now, and the palette's hand-sorted rows are what that rule has to agree
    /// with — or a preset would change its text the day the rule replaced the list.
    func testDarkBackgroundsUseWhiteText() {
        for background in WidgetBackground.dark {
            XCTAssertEqual(background.foregroundColor, NSColor(calibratedWhite: 1, alpha: 1), background.title)
        }
    }

    func testNothingHasBeenPickedBeforeAPersonPicksIt() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())

        XCTAssertNil(store.customColor)
        XCTAssertFalse(store.selected.isCustom)
    }

    func testPersistsAColourOfThePersonsOwn() throws {
        let preferences = try isolatedPreferences()

        WidgetBackgroundStore(preferences: preferences).select(try custom("#336699"))

        let reopened = WidgetBackgroundStore(preferences: preferences)
        XCTAssertTrue(reopened.selected.isCustom)
        XCTAssertEqual(reopened.selected.color.srgbHex, "#336699")
    }

    /// Kept under its own key for this: a person who tries a preset and comes back finds their
    /// colour still offered, instead of having to find it on the wheel again.
    func testTheOwnColourOutlivesADetourThroughAPreset() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())

        store.select(try custom("#336699"))
        store.select(.mint)

        XCTAssertEqual(store.selected, .mint)
        XCTAssertEqual(store.customColor?.srgbHex, "#336699")
    }

    /// The file is meant to be corrected by hand, so `custom` with nothing readable behind it is
    /// a real input — and the app's own background is the answer to it, as it is to a mistyped
    /// preset name.
    func testCustomWithNoColourBehindItReadsAsGraphite() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetBackgroundStore(preferences: preferences)
        preferences.set("custom", forKey: "widgetBackground")

        for unreadable in [WidgetBackgroundStore.noCustomColor, "#12345", "teal"] {
            preferences.set(unreadable, forKey: "widgetBackgroundCustomColor")
            XCTAssertEqual(store.selected, .graphite, unreadable)
        }
    }

    /// The wheel reports every shade the pointer passes, and each report rebuilds every row in
    /// the widget: a shade that is the same colour at the file's precision is not a change.
    func testAnOwnColourThatHasNotMovedIsNotWrittenAgain() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.select(try custom("#336699"))
        store.select(try custom("#336699"))
        let sameAtTheFilesPrecision = try XCTUnwrap(
            WidgetBackground(custom: NSColor(srgbRed: 0.2001, green: 0.4001, blue: 0.6001, alpha: 1)))
        store.select(sameAtTheFilesPrecision)
        XCTAssertEqual(changes, 1)

        store.select(try custom("#336698"))
        XCTAssertEqual(changes, 2)

        // And coming back to the same colour from a preset is a change: the widget moves.
        store.select(.mint)
        store.select(try custom("#336698"))
        XCTAssertEqual(changes, 4)
        XCTAssertTrue(store.selected.isCustom)
    }

    /// Either side of where the rule turns over, so a change to the text colours or to the
    /// arithmetic that moves the line shows up here rather than on somebody's widget.
    func testAnOwnColourTakesTheTextThatStandsOutFromIt() throws {
        let white = NSColor(calibratedWhite: 1, alpha: 1)
        let darkText = WidgetBackground.pearl.foregroundColor

        XCTAssertEqual(try custom("#828282").foregroundColor, white)
        XCTAssertEqual(try custom("#838383").foregroundColor, darkText)
        XCTAssertEqual(try custom("#0000FF").foregroundColor, white)
        XCTAssertEqual(try custom("#FFFF00").foregroundColor, darkText)
    }

    /// A colour with no `#RRGGBB` spelling cannot be kept, so it is refused where it is made
    /// rather than drawn once and lost at the next launch.
    func testAColourTheFileCannotKeepIsNotABackground() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))

        XCTAssertNil(WidgetBackground(custom: pattern))
    }

    private func custom(_ hex: String) throws -> WidgetBackground {
        try XCTUnwrap(NSColor(hex: hex).flatMap(WidgetBackground.init(custom:)))
    }

    func testTellsItsOneListenerWhichSettingChanged() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())
        var changed: [WidgetSetting] = []
        store.onChange = { changed.append($0) }

        store.select(.mint)
        store.selectOpacity(0.5)

        XCTAssertEqual(changed, [.background, .backgroundOpacity])
    }
}
