import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The themes on offer, the one in use, and the file a person's own colours become.
///
/// A theme is a file meant to be written by hand or by somebody else, so what the tests hold
/// to is what a sparse, broken or foreign file does — and that the built-in theme is always
/// there to fall back on.
@MainActor
final class ThemeStoreTests: XCTestCase {
    /// Anything a file leaves out is the built-in theme's, so a theme that names a single
    /// colour is a theme, not an error.
    func testAThemeFileMissingFieldsIsReadWithTheDefaults() throws {
        let folder = try themesFolder()
        try write(##"{"name": "Sparse", "light": {}, "dark": {"background": "#112233"}}"##, to: folder, as: "Sparse")

        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        XCTAssertEqual(store.problems, [])
        let sparse = try XCTUnwrap(store.themes.first { $0.name == "Sparse" })
        XCTAssertEqual(sparse.dark.widgetBackground.color.srgbHex, "#112233")
        XCTAssertEqual(sparse.light.background, "#006996")
        XCTAssertTrue(sparse.light.lampScheme.isDefault)
        XCTAssertEqual(
            sparse.dark.accent(for: .working).srgbHex,
            NSColor(hex: try XCTUnwrap(WidgetTheme.attention[SessionAttention.working.rawValue]))?.srgbHex
        )
    }

    /// A file that cannot be read is named, with what was wrong, and costs nothing else: the
    /// built-in theme is still offered and still the one in use.
    func testABrokenFileIsReportedAndTheBuiltInThemeIsStillOffered() throws {
        let folder = try themesFolder()
        try write("not a theme", to: folder, as: "Broken")

        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        XCTAssertEqual(store.problems.count, 1)
        XCTAssertTrue(store.problems[0].hasPrefix("Broken.json"), store.problems[0])
        XCTAssertEqual(store.themes, [.standard])
        XCTAssertEqual(store.theme, .standard)
    }

    /// Colours chosen by hand in a version before themes become a theme of their own, in use,
    /// so the update does not change anybody's widget.
    func testLampColoursSetByHandBecomeMyThemeAndAreSelected() throws {
        let folder = try themesFolder()
        let preferences = try isolatedPreferences()
        let store = ThemeStore(preferences: preferences, folder: folder)
        var lamps = LampScheme()
        lamps.setColor(NSColor(sRGB: "#336699"), for: .executing)

        store.adoptIfNeeded(lampScheme: lamps, background: .defaultBackground)

        XCTAssertEqual(store.theme.name, "My Theme")
        XCTAssertEqual(store.mode, .auto)
        XCTAssertEqual(store.theme.dark.lampScheme.style(for: .executing).color.srgbHex, "#336699")
        XCTAssertEqual(store.theme.light.lampScheme.style(for: .executing).color.srgbHex, "#336699")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("My Theme.json").path))
    }

    /// Adoption is a one-time carry-over: once a theme has been chosen, the old colours are
    /// history and must not take its place.
    func testNothingIsAdoptedOnceAThemeHasBeenChosen() throws {
        let folder = try themesFolder()
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)
        store.select(WidgetTheme.standard)
        var lamps = LampScheme()
        lamps.setColor(NSColor(sRGB: "#336699"), for: .executing)

        store.adoptIfNeeded(lampScheme: lamps, background: .defaultBackground)

        XCTAssertEqual(store.theme, .standard)
        XCTAssertEqual(store.themes, [.standard])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("My Theme.json").path))
    }

    /// The app's own colours are the built-in theme already; copying them into a file would
    /// only be a second name for the same thing.
    func testTheAppsOwnColoursAreNotAdopted() throws {
        let folder = try themesFolder()
        let preferences = try isolatedPreferences()
        let store = ThemeStore(preferences: preferences, folder: folder)

        store.adoptIfNeeded(lampScheme: LampScheme(), background: .defaultBackground)

        XCTAssertNil(preferences.string(forKey: "theme"))
        XCTAssertEqual(store.themes, [.standard])
    }

    /// Duplicating is how editing starts: the copy is a file of its own, selected, with a name
    /// that does not collide with one already on offer.
    func testDuplicateWritesACopyAndSelectsIt() throws {
        let folder = try themesFolder()
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        let first = try XCTUnwrap(store.duplicate())

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(store.theme.name, "Default copy")
        XCTAssertEqual(store.theme.dark, WidgetTheme.standard.dark)

        store.select(WidgetTheme.standard)
        store.duplicate()

        XCTAssertEqual(store.theme.name, "Default copy 2")
        XCTAssertEqual(Set(store.themes.map(\.name)), ["Default", "Default copy", "Default copy 2"])
    }

    /// Light and dark pick their half of the theme whatever the Mac's own appearance is.
    func testTheModeChoosesTheMatchingLook() throws {
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: nil)
        var changed: [WidgetSetting] = []
        store.onChange = { changed.append($0) }

        store.select(ThemeMode.light)
        XCTAssertEqual(store.mode, .light)
        XCTAssertFalse(store.isDark)
        XCTAssertEqual(store.look, WidgetTheme.standard.light)

        store.select(ThemeMode.dark)
        XCTAssertEqual(store.mode, .dark)
        XCTAssertTrue(store.isDark)
        XCTAssertEqual(store.look, WidgetTheme.standard.dark)

        XCTAssertEqual(changed, [.theme, .theme])
    }

    private func themesFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchThemes.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func write(_ text: String, to folder: URL, as name: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(name).json"))
    }
}
