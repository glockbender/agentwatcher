import AppKit
import XCTest

@testable import AgentWatchApp

final class HUDPlacementTests: XCTestCase {
    private let primaryScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    private let secondaryScreen = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
    private let widgetSize = NSSize(width: 360, height: 160)
    private let margin: CGFloat = 16

    func testUsesTheUpperRightCornerOfThePrimaryScreenWithoutSavedPosition() {
        let origin = HUDPlacement.origin(
            savedOrigin: nil,
            size: widgetSize,
            visibleFrames: [primaryScreen, secondaryScreen],
            primaryVisibleFrame: primaryScreen,
            margin: margin
        )

        XCTAssertEqual(origin, NSPoint(x: 1_064, y: 724))
    }

    func testRestoresAValidPositionOnAnotherConnectedScreen() {
        let origin = HUDPlacement.origin(
            savedOrigin: NSPoint(x: 1_800, y: 600),
            size: widgetSize,
            visibleFrames: [primaryScreen, secondaryScreen],
            primaryVisibleFrame: primaryScreen,
            margin: margin
        )

        XCTAssertEqual(origin, NSPoint(x: 1_800, y: 600))
    }

    func testMovesAnOffScreenSavedPositionInsideThePrimaryScreen() {
        let origin = HUDPlacement.origin(
            savedOrigin: NSPoint(x: 4_000, y: -100),
            size: widgetSize,
            visibleFrames: [primaryScreen],
            primaryVisibleFrame: primaryScreen,
            margin: margin
        )

        XCTAssertEqual(origin, NSPoint(x: 1_064, y: 724))
    }

    func testClampsARestoredPositionWhenTheWidgetGrew() {
        let origin = HUDPlacement.origin(
            savedOrigin: NSPoint(x: 1_200, y: 800),
            size: widgetSize,
            visibleFrames: [primaryScreen],
            primaryVisibleFrame: primaryScreen,
            margin: margin
        )

        XCTAssertEqual(origin, NSPoint(x: 1_064, y: 724))
    }

    /// A reset is about finding the widget again, so it goes to the middle rather than back
    /// to the corner a first launch uses.
    func testTheResetPositionIsTheMiddleOfTheScreen() {
        let origin = HUDPlacement.centeredOrigin(for: widgetSize, in: primaryScreen)

        XCTAssertEqual(origin, NSPoint(x: 540, y: 370))
        XCTAssertEqual(origin.x + widgetSize.width / 2, primaryScreen.midX)
        XCTAssertEqual(origin.y + widgetSize.height / 2, primaryScreen.midY)
    }

    /// Centring a widget wider than its screen would hang it off both edges at once, leaving
    /// nothing to grab.
    func testAWidgetLargerThanItsScreenIsPinnedToTheNearEdge() {
        let tiny = NSRect(x: 100, y: 50, width: 200, height: 100)

        let origin = HUDPlacement.centeredOrigin(for: widgetSize, in: tiny)

        XCTAssertEqual(origin, NSPoint(x: 100, y: 50))
    }

    func testPositionStorePersistsTheMostRecentOrigin() throws {
        let preferences = try isolatedPreferences()
        let store = HUDFrameStore(preferences: preferences)

        store.save(NSPoint(x: 350, y: 400))

        XCTAssertEqual(store.savedOrigin, NSPoint(x: 350, y: 400))
    }

    /// Following the session count is a value, not a missing size, so an untouched widget
    /// has both a size to open at and a stated reason the height keeps moving.
    func testTheWidgetSizesItselfUntilItIsResizedByHand() throws {
        let preferences = try isolatedPreferences()
        let store = HUDFrameStore(preferences: preferences)

        XCTAssertTrue(store.sizeFollowsSessions, "an untouched widget must stay free to size itself")
        XCTAssertEqual(store.size, HUDFrameStore.defaultSize)

        store.save(NSSize(width: 420, height: 260))
        XCTAssertEqual(store.size, NSSize(width: 420, height: 260))
        XCTAssertFalse(store.sizeFollowsSessions, "a size chosen by hand is what ends the following")

        store.resetSize()
        XCTAssertTrue(store.sizeFollowsSessions)
        XCTAssertEqual(store.size, HUDFrameStore.defaultSize, "a reset writes the size back, it does not drop it")
    }

    func testASavedSizeIsNeverSmallerThanTheWidgetCanUsefullyBe() throws {
        let preferences = try isolatedPreferences()
        let store = HUDFrameStore(preferences: preferences)

        store.save(NSSize(width: 10, height: 10))

        XCTAssertEqual(store.size, HUDFrameStore.minimumSize)
    }
}
