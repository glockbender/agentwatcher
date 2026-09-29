import AppKit
import XCTest

@testable import AgentWatchApp

final class WidgetBackgroundStoreTests: XCTestCase {
    func testUsesBlueWhenNoPreferenceWasSaved() throws {
        let preferences = try isolatedPreferences()

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).selected, .defaultBackground)
    }

    /// Read only now — the theme chooses the colour — but an older file still names a preset,
    /// and `ThemeStore.adoptIfNeeded` needs it read to carry it over.
    func testReadsAPresetAnOlderFileNamed() throws {
        let preferences = try isolatedPreferences()
        preferences.set("mint", forKey: "widgetBackground")

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).selected, .mint)
    }

    func testUsesTheExistingBackgroundOpacityByDefault() throws {
        let preferences = try isolatedPreferences()

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).opacity, 0.82)
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

        for background in [WidgetBackground.pearl, .sand, .mint, .sky] {
            XCTAssertEqual(background.foregroundColor, expectedForeground)
            XCTAssertEqual(background.secondaryForegroundColor, expectedSecondary)
        }
    }

    /// The other half of the rule the light presets are held to: a colour's own brightness
    /// decides its text now, and the palette's hand-sorted rows are what that rule has to agree
    /// with — or a preset would change its text the day the rule replaced the list.
    func testDarkBackgroundsUseWhiteText() {
        for background in [WidgetBackground.graphite, .midnight, .forest, .plum, .cocoa, .slate] {
            XCTAssertEqual(background.foregroundColor, NSColor(calibratedWhite: 1, alpha: 1), background.title)
        }
    }

    func testNothingHasBeenPickedBeforeAPersonPicksIt() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())

        XCTAssertNil(store.customColor)
        XCTAssertEqual(store.selected.color.srgbHex, "#006996")
    }

    func testReadsAColourOfThePersonsOwnAnOlderFileKept() throws {
        let preferences = try isolatedPreferences()
        preferences.set("custom", forKey: "widgetBackground")
        preferences.set("#336699", forKey: "widgetBackgroundCustomColor")

        let reopened = WidgetBackgroundStore(preferences: preferences)
        XCTAssertTrue(reopened.selected.isCustom)
        XCTAssertEqual(reopened.selected.color.srgbHex, "#336699")
    }

    /// The file is meant to be corrected by hand, so `custom` with nothing readable behind it is
    /// a real input — and the app's own background is the answer to it, as it is to a mistyped
    /// preset name.
    func testCustomWithNoColourBehindItReadsAsDefaultBlue() throws {
        let preferences = try isolatedPreferences()
        let store = WidgetBackgroundStore(preferences: preferences)
        preferences.set("custom", forKey: "widgetBackground")

        for unreadable in ["", "#12345", "teal"] {
            preferences.set(unreadable, forKey: "widgetBackgroundCustomColor")
            XCTAssertEqual(store.selected, .defaultBackground, unreadable)
        }
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

    func testPersistsTheChosenMaterial() throws {
        let preferences = try isolatedPreferences()
        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).material, .glass)

        WidgetBackgroundStore(preferences: preferences).selectMaterial(.solid)

        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).material, .solid)
    }

    func testTellsItsOneListenerWhichSettingChanged() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())
        var changed: [WidgetSetting] = []
        store.onChange = { changed.append($0) }

        store.selectMaterial(.frosted)
        store.selectOpacity(0.5)

        XCTAssertEqual(changed, [.background, .backgroundOpacity])
    }
}
