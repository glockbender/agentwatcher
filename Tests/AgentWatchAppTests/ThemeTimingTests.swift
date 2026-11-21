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

        XCTAssertEqual(timing.dot.ringDiameter, 24)
        XCTAssertFalse(timing.dot.isOnTheRight)
        XCTAssertEqual(timing.dot.inset, WidgetTheme.Timing.Dot().inset)
        XCTAssertEqual(timing.widget, WidgetTheme.Timing.Widget())
    }

    func testBeaconDiameterRoundTripsAndStaysInsideItsClickTarget() throws {
        var dot = WidgetTheme.Timing.Dot()
        dot.ringDiameter = 30
        let data = try JSONEncoder().encode(dot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetTheme.Timing.Dot.self, from: data).ringDiameter, 30)
        dot.ringDiameter = 100
        XCTAssertEqual(dot.clamped.ringDiameter, 34)
        dot.ringDiameter = 0
        XCTAssertEqual(dot.clamped.ringDiameter, 20)
    }

    func testANumberOutOfRangeIsHeldToIt() {
        var timing = WidgetTheme.Timing()
        timing.widget.glassTint = 7
        timing.dot.inset = .nan
        timing.dot.corner = "bottom"

        let clamped = timing.clamped

        XCTAssertEqual(clamped.widget.glassTint, 1)
        XCTAssertEqual(clamped.dot.inset, WidgetTheme.Timing.Dot().inset)
        XCTAssertEqual(clamped.dot.corner, "topRight")
    }

    func testATranslucentColourKeepsItsAlphaThroughAFile() throws {
        let colour = try XCTUnwrap(NSColor(hex: "#FFFFFFAD"))

        XCTAssertEqual(colour.alphaComponent, 0xAD / 255, accuracy: 0.001)
        XCTAssertEqual(colour.srgbHexWithAlpha, "#FFFFFFAD")
        XCTAssertEqual(NSColor(hex: "#1A1F26")?.srgbHexWithAlpha, "#1A1F26")
    }
}
