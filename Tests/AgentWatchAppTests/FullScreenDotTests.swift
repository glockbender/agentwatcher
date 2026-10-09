import AppKit
import XCTest

@testable import AgentWatchApp

/// The full-screen dot's colour cycle: every state that holds sessions gets its share of the
/// two seconds, and fades into the next.
@MainActor
final class FullScreenDotTests: XCTestCase {
    func testEachStateHoldsItsShareAndFadesIntoTheNext() {
        let frames = FullScreenDot.cycle([(.orange, 1), (.blue, 3)])

        assertEqual(frames.map(\.time), [0, 0.175, 0.25, 0.775, 1], accuracy: 0.0001)
        XCTAssertEqual(frames.map(\.color), [.orange, .orange, .blue, .blue, .orange])
    }

    func testNothingToShowIsNoCycle() {
        XCTAssertTrue(FullScreenDot.cycle([]).isEmpty)
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

    func testThePointerInTheMenuBarBandOfThatScreenOnly() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

        XCTAssertTrue(FullScreenDot.isInMenuBar(NSPoint(x: 1400, y: 982), screen: screen, height: 37))
        XCTAssertTrue(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 946), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 944), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 1600, y: 982), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 990), screen: screen, height: 37))
    }
}

private func assertEqual(
    _ values: [Double], _ expected: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, want) in zip(values, expected) {
        XCTAssertEqual(value, want, accuracy: accuracy, file: file, line: line)
    }
}
