import AppKit
import XCTest

@testable import AgentWatchApp

/// Which text a colour takes: the one that stands out from it more, by WCAG contrast.
@MainActor
final class WidgetBackgroundTests: XCTestCase {
    func testLightBackgroundsUseDarkTextIndependentOfSystemAppearance() throws {
        for background in [WidgetBackground.pearl, try custom("#FAEDD6"), try custom("#E0F5EB")] {
            XCTAssertEqual(background.foregroundColor.srgbHex, "#222933")
            XCTAssertEqual(background.secondaryForegroundColor.srgbHexWithAlpha, "#5C6774")
        }
    }

    func testDarkBackgroundsUseWhiteText() throws {
        for background in [WidgetBackground.graphite, .defaultBackground, try custom("#2B1A38")] {
            XCTAssertEqual(background.foregroundColor.srgbHex, "#FFFFFF", "\(background.color)")
            XCTAssertEqual(background.secondaryForegroundColor.srgbHexWithAlpha, "#FFFFFFAD", "\(background.color)")
        }
    }

    /// Either side of where the rule turns over, so a change to the text colours or to the
    /// arithmetic that moves the line shows up here rather than on somebody's widget.
    func testAnOwnColourTakesTheTextThatStandsOutFromIt() throws {
        XCTAssertEqual(try custom("#828282").foregroundColor.srgbHex, "#FFFFFF")
        XCTAssertEqual(try custom("#838383").foregroundColor.srgbHex, "#222933")
        XCTAssertEqual(try custom("#0000FF").foregroundColor.srgbHex, "#FFFFFF")
        XCTAssertEqual(try custom("#FFFF00").foregroundColor.srgbHex, "#222933")
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
