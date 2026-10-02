import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The panel under the widget. Liquid Glass itself is drawn only on macOS 26 by a build of
/// Xcode 26, so what is checked here is what every material shares: where the content goes,
/// what the text is drawn for, and how much colour the glass would take.
@MainActor
final class WidgetBackdropTests: XCTestCase {
    /// On glass the desktop is behind the text, so the text follows the mode; on the others it
    /// is drawn for the theme's own colour.
    func testTextOnGlassFollowsTheModeAndElsewhereTheThemesColour() {
        let look = WidgetTheme.standard.dark
        let theme = look.widgetBackground
        for material in [WidgetMaterial.glass, .clearGlass] {
            XCTAssertEqual(material.textBackground(for: look, dark: true), .graphite, material.rawValue)
            XCTAssertEqual(material.textBackground(for: look, dark: false), .pearl, material.rawValue)
        }
        for material in [WidgetMaterial.frosted, .solid] {
            XCTAssertEqual(material.textBackground(for: look, dark: true), theme, material.rawValue)
            XCTAssertEqual(material.textBackground(for: look, dark: false), theme, material.rawValue)
        }
    }

    /// A hint of the colour, scaled by the opacity slider: half of it at full opacity, a quarter
    /// on clear glass, and nothing is kept back as a floor.
    func testTheGlassTakesTheColourInProportionToTheOpacity() {
        let colour = NSColor(sRGB: "#006996")
        XCTAssertEqual(glassTint(colour, opacity: 1).alphaComponent, 0.5, accuracy: 0.001)
        XCTAssertEqual(glassTint(colour, opacity: 1, clear: true).alphaComponent, 0.25, accuracy: 0.001)
        XCTAssertEqual(glassTint(colour, opacity: 0.1).alphaComponent, 0.05, accuracy: 0.001)
    }

    /// Where glass is not drawn, the content is a view of its own above the surface, so it
    /// stays at full strength while a frosted surface fades with the opacity.
    func testContentSitsAboveTheSurfaceWhereThereIsNoGlass() {
        for material in [WidgetMaterial.frosted, .solid] {
            let backdrop = Backdrop(cornerRadius: 8, tint: .red, opacity: 0.5, material: material)
            XCTAssertTrue(backdrop.content.superview === backdrop, material.rawValue)
            XCTAssertTrue(backdrop.subviews.last === backdrop.content, material.rawValue)
            XCTAssertEqual(backdrop.content.alphaValue, 1, material.rawValue)
        }
    }

    /// Everything the widget shows goes into the backdrop's content, which on glass is inside
    /// the glass: a view added to the backdrop itself would sit outside it on macOS 26.
    func testEveryPartOfTheWidgetGoesIntoTheBackdropsContent() throws {
        let session = SampleSession.make(id: "codex:backdrop", phase: .executing)
        let list = HUDSessionListView(
            models: [HUDRowModel(snapshot: session, now: .now, layout: .standard)],
            usageLimits: [],
            now: .now,
            availableWidth: 400,
            focus: { _ in },
            remove: { _ in },
            background: .defaultBackground,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
        let backdrop = try XCTUnwrap(list.subviews.compactMap { $0 as? Backdrop }.first)
        let surface = try XCTUnwrap(backdrop.subviews.first)
        XCTAssertFalse(backdrop.content.subviews.isEmpty)
        XCTAssertEqual(
            backdrop.subviews.filter { $0 !== surface && $0 !== backdrop.content }.count, 0,
            "nothing but the surface and the content lies on the backdrop itself")
    }
}
