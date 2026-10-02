import AppKit
import XCTest

@testable import AgentWatchApp

/// The theme's timing: a file that says nothing about it, or only part of it, still reads, and a
/// number out of range is held to the range the Timing page offers.
final class ThemeTimingTests: XCTestCase {
    func testAThemeWithoutTimingTakesTheDefaults() throws {
        let theme = try JSONDecoder().decode(WidgetTheme.self, from: Data(#"{"name": "Old"}"#.utf8))

        XCTAssertEqual(theme.timing, WidgetTheme.Timing())
    }

    func testAPartOfTheTimingKeepsTheRestAsDefault() throws {
        let json = #"{"name": "Mine", "timing": {"dot": {"diameter": 12, "corner": "topLeft"}}}"#
        let timing = try JSONDecoder().decode(WidgetTheme.self, from: Data(json.utf8)).timing

        XCTAssertEqual(timing.dot.diameter, 12)
        XCTAssertFalse(timing.dot.isOnTheRight)
        XCTAssertEqual(timing.dot.inset, WidgetTheme.Timing.Dot().inset)
        XCTAssertEqual(timing.widget, WidgetTheme.Timing.Widget())
    }

    func testANumberOutOfRangeIsHeldToIt() {
        var timing = WidgetTheme.Timing()
        timing.widget.glassTint = 7
        timing.dot.diameter = .nan
        timing.dot.corner = "bottom"

        let clamped = timing.clamped

        XCTAssertEqual(clamped.widget.glassTint, 1)
        XCTAssertEqual(clamped.dot.diameter, WidgetTheme.Timing.Dot().diameter)
        XCTAssertEqual(clamped.dot.corner, "topRight")
    }

    func testATranslucentColourKeepsItsAlphaThroughAFile() throws {
        let colour = try XCTUnwrap(NSColor(hex: "#FFFFFFAD"))

        XCTAssertEqual(colour.alphaComponent, 0xAD / 255, accuracy: 0.001)
        XCTAssertEqual(colour.srgbHexWithAlpha, "#FFFFFFAD")
        XCTAssertEqual(NSColor(hex: "#1A1F26")?.srgbHexWithAlpha, "#1A1F26")
    }
}
