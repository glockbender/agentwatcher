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

    func testTellsItsOneListenerWhichSettingChanged() throws {
        let store = WidgetBackgroundStore(preferences: try isolatedPreferences())
        var changed: [WidgetSetting] = []
        store.onChange = { changed.append($0) }

        store.select(.mint)
        store.selectOpacity(0.5)

        XCTAssertEqual(changed, [.background, .backgroundOpacity])
    }
}
