import AppKit
import XCTest

@testable import AgentWatchApp

/// Which text a colour takes: the one that stands out from it more, by WCAG contrast.
final class WidgetBackgroundTests: XCTestCase {
    func testLightBackgroundsUseDarkTextIndependentOfSystemAppearance() throws {
        let expectedForeground = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        let expectedSecondary = NSColor(calibratedRed: 0.29, green: 0.33, blue: 0.38, alpha: 1)

        for background in [WidgetBackground.pearl, try custom("#FAEDD6"), try custom("#E0F5EB")] {
            XCTAssertEqual(background.foregroundColor, expectedForeground)
            XCTAssertEqual(background.secondaryForegroundColor, expectedSecondary)
        }
    }

    func testDarkBackgroundsUseWhiteText() throws {
        for background in [WidgetBackground.graphite, .defaultBackground, try custom("#2B1A38")] {
            XCTAssertEqual(background.foregroundColor, NSColor(calibratedWhite: 1, alpha: 1), "\(background.color)")
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
}
