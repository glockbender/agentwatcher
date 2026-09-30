import AppKit
import XCTest

@testable import AgentWatchApp

/// The full-screen dot's colour cycle: every state that holds sessions gets its share of the
/// two seconds, and fades into the next.
@MainActor
final class FullScreenDotTests: XCTestCase {
    func testEachStateHoldsItsShareAndFadesIntoTheNext() {
        let frames = FullScreenDot.cycle([(.orange, 1), (.blue, 3)])

        XCTAssertEqual(frames.map(\.time), [0, 0.175, 0.25, 0.775, 1], accuracy: 0.0001)
        XCTAssertEqual(frames.map(\.color), [.orange, .orange, .blue, .blue, .orange])
    }

    func testNothingToShowIsNoCycle() {
        XCTAssertTrue(FullScreenDot.cycle([]).isEmpty)
    }

    func testThePointerInTheMenuBarBandOfThatScreenOnly() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

        XCTAssertTrue(FullScreenDot.isInMenuBar(NSPoint(x: 1400, y: 982), screen: screen, height: 37))
        XCTAssertTrue(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 946), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 944), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 1600, y: 982), screen: screen, height: 37))
        XCTAssertFalse(FullScreenDot.isInMenuBar(NSPoint(x: 10, y: 990), screen: screen, height: 37))
    }
}

private func XCTAssertEqual(
    _ values: [Double], _ expected: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(values.count, expected.count, file: file, line: line)
    for (value, want) in zip(values, expected) {
        XCTAssertEqual(value, want, accuracy: accuracy, file: file, line: line)
    }
}
