import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class FullScreenDotTests: XCTestCase {
    func testAllModesIncludesWindowedDisplaysOnlyWhileWaiting() throws {
        let screens = NSScreen.screens
        let display = try XCTUnwrap(screens.first)
        var checks = 0
        func targets(_ scope: WaitingBeaconScope, _ count: Int, enabled: Bool = true) -> [NSScreen] {
            FullScreenDot.targetScreens(waitingCount: count, enabled: enabled, scope: scope, screens: screens) { _ in
                checks += 1
                return []
            }
        }
        XCTAssertEqual(targets(.allModes, 2), screens)
        XCTAssertTrue(targets(.allModes, 0).isEmpty)
        XCTAssertTrue(targets(.allModes, 2, enabled: false).isEmpty)
        XCTAssertTrue(targets(.fullScreenOnly, 0).isEmpty)
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(targets(.fullScreenOnly, 1).isEmpty)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(
            FullScreenDot.targetScreens(waitingCount: 1, enabled: true, scope: .fullScreenOnly, screens: screens) { _ in
                [display]
            }, [display])
    }

    func testBeaconBelowMenuHasRoomForTheWholeTargetInEitherCorner() {
        let display = CGRect(x: -1512, y: 250, width: 1512, height: 982)
        let right = FullScreenDot.frame(on: display, menuHeight: 37, right: true, inset: 12)
        let left = FullScreenDot.frame(on: display, menuHeight: 37, right: false, inset: 12)
        XCTAssertEqual(right.size, NSSize(width: 44, height: 44))
        XCTAssertEqual(right.maxY, display.maxY - 37 - 4)
        XCTAssertEqual(right.maxX, display.maxX - 12)
        XCTAssertEqual(left.minX, display.minX + 12)
        XCTAssertEqual(left.maxY, right.maxY)
    }

    func testBeaconIsAnActionWithAnAccessibleExactCountEvenWhenTheNumberIsAbbreviated() {
        var opened = 0
        let beacon = WaitingBeaconButton { opened += 1 }
        beacon.showCount(126)
        XCTAssertEqual(beacon.title, "99+")
        XCTAssertEqual(beacon.accessibilityLabel(), "126 chats waiting for a reply")
        beacon.performClick(nil)
        XCTAssertEqual(opened, 1)
    }

    func testBeaconSizeKeepsTheClickTargetAndItsContextMenuOpensSettings() throws {
        var settingsOpened = false
        var chatsOpened = false
        let beacon = WaitingBeaconButton(openSettings: { settingsOpened = true }) { chatsOpened = true }
        XCTAssertEqual(beacon.diameter, 24)
        beacon.setDiameter(30)
        XCTAssertEqual(beacon.diameter, 30)
        XCTAssertEqual(beacon.bounds.size, NSSize(width: 44, height: 44))
        let menu = try XCTUnwrap(beacon.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Waiting Beacon Settings…"])
        menu.performActionForItem(at: 0)
        XCTAssertTrue(settingsOpened)
        XCTAssertFalse(chatsOpened)
    }

    func testReduceMotionStopsTheOrbitAndKeepsTheCount() {
        let beacon = WaitingBeaconButton {}
        beacon.showCount(3)
        beacon.setRotating(true)
        XCTAssertTrue(beacon.isRotating)
        beacon.setRotating(false)
        XCTAssertFalse(beacon.isRotating)
        XCTAssertEqual(beacon.title, "3")
    }

    /// A full-screen window with tabs or a toolbar is two windows. Measured on macOS 15.7.7 with
    /// Ghostty 1.3.1 and three tabs: the tab bar 72 points tall at the top, the terminal from 28
    /// points down to the bottom. Neither covers the screen alone, and the dot never showed.
    func testAFullScreenWindowWithItsTabBarAsASecondWindowCoversTheScreen() {
        XCTAssertTrue(
            FullScreenDot.isCovered(
                screen, topInset: 0, primaryHeight: 1117,
                by: [
                    (owner: 7, bounds: CGRect(x: 0, y: 0, width: 1728, height: 72)),
                    (owner: 7, bounds: CGRect(x: 0, y: 28, width: 1728, height: 1089)),
                ]))
    }

    func testOneWindowEdgeToEdgeCoversTheScreen() {
        XCTAssertTrue(
            FullScreenDot.isCovered(
                screen, topInset: 0, primaryHeight: 1117,
                by: [(owner: 7, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))]))
    }

    /// Measured on macOS 26.5: under a notch a full-screen window starts below the 33-point band.
    func testUnderANotchTheWindowMayStartBelowIt() {
        XCTAssertTrue(
            FullScreenDot.isCovered(
                screen, topInset: 33, primaryHeight: 1117,
                by: [(owner: 7, bounds: CGRect(x: 0, y: 33, width: 1728, height: 1084))]))
    }

    /// A zoomed window stops at the menu bar, which is on screen: no reason for the dot.
    func testAWindowZoomedUnderTheMenuBarDoesNotCoverTheScreen() {
        XCTAssertFalse(
            FullScreenDot.isCovered(
                screen, topInset: 0, primaryHeight: 1117,
                by: [(owner: 7, bounds: CGRect(x: 0, y: 25, width: 1728, height: 1092))]))
    }

    func testTwoApplicationsDoNotAddUpToAFullScreenWindow() {
        XCTAssertFalse(
            FullScreenDot.isCovered(
                screen, topInset: 0, primaryHeight: 1117,
                by: [
                    (owner: 7, bounds: CGRect(x: 0, y: 0, width: 1728, height: 72)),
                    (owner: 8, bounds: CGRect(x: 0, y: 28, width: 1728, height: 1089)),
                ]))
    }

    func testAGapBetweenTheWindowsIsNoCover() {
        XCTAssertFalse(
            FullScreenDot.isCovered(
                screen, topInset: 0, primaryHeight: 1117,
                by: [
                    (owner: 7, bounds: CGRect(x: 0, y: 0, width: 1728, height: 72)),
                    (owner: 7, bounds: CGRect(x: 0, y: 100, width: 1728, height: 1017)),
                ]))
    }

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
}
