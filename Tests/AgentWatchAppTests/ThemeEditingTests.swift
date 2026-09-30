import AgentWatchCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

/// What the settings window does to a theme: the editor's writes, and the list's actions.
@MainActor
final class ThemeEditingTests: XCTestCase {
    /// The built-in theme is never written. The first change makes a copy of it, puts the copy
    /// in use, and lands in both of its looks unless told otherwise.
    func testTheFirstChangeToTheBuiltInThemeGoesIntoACopyAndBothLooks() throws {
        let (model, themes) = try makeModel()

        model.editTheme { $0.widgetOpacity = 0.5 }

        XCTAssertEqual(themes.theme.name, "Default copy")
        XCTAssertEqual(themes.theme.light.widgetOpacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(themes.theme.dark.widgetOpacity, 0.5, accuracy: 0.0001)
        XCTAssertNil(model.themeProblem)
        XCTAssertEqual(themes.themes.first, .standard, "the built-in theme itself did not change")
    }

    /// Told to, a change goes into one look only, and the editor shows that look.
    func testAChangeCanGoIntoOneLookOnly() throws {
        let (model, themes) = try makeModel()
        model.themeScope = .light

        model.editTheme { $0.setBackground(NSColor(sRGB: "#112233")) }

        XCTAssertEqual(themes.theme.light.background, "#112233")
        XCTAssertEqual(themes.theme.dark.background, WidgetTheme.standard.dark.background)
        XCTAssertEqual(model.editedLook.background, "#112233")
    }

    /// A name already taken is refused and said, and the theme keeps the one it had.
    func testARenameToATakenNameIsRefusedAndSaid() throws {
        let (model, themes) = try makeModel()
        try themes.create(named: "Other")
        try themes.create(named: "Mine")

        model.changeTheme { $0.name = "Other" }

        XCTAssertEqual(themes.theme.name, "Mine")
        XCTAssertEqual(model.themeProblem, ThemeStore.Problem.nameTaken("Other").errorDescription)

        model.changeTheme { $0.name = "Renamed" }

        XCTAssertEqual(themes.theme.name, "Renamed")
        XCTAssertNil(model.themeProblem)
    }

    /// A new theme is the built-in colours under a free name, in use and open in the editor.
    func testANewThemeOpensInTheEditor() throws {
        let (model, themes) = try makeModel()
        model.go(.appearance)

        model.newTheme()

        XCTAssertEqual(themes.theme.name, "New Theme")
        XCTAssertEqual(model.page, .theme)
        XCTAssertEqual(model.page.parent, .appearance, "the sidebar keeps Appearance lit")
    }

    /// Editing a theme from the list puts it in use first: the editor changes what is on screen.
    func testEditingFromTheListPutsTheThemeInUse() throws {
        let (model, themes) = try makeModel()
        let first = try themes.create(named: "First")
        try themes.create(named: "Second")

        model.edit(first)

        XCTAssertEqual(themes.theme.name, "First")
        XCTAssertEqual(model.page, .theme)
    }

    func testDeletingFromTheListFallsBackToTheBuiltInTheme() throws {
        let (model, themes) = try makeModel()
        let mine = try themes.create(named: "Mine")

        model.delete(mine)

        XCTAssertEqual(themes.theme, .standard)
        XCTAssertEqual(themes.customThemes, [])
    }

    /// The editor fits the settings window as it opens: 760 points, of which the sidebar
    /// takes about 190. One table of six columns for the states asked for 640, and the page
    /// cut off the lamps' samples on the right.
    func testTheEditorFitsTheWindowAsItOpens() throws {
        let (model, themes) = try makeModel()
        try themes.create(named: "Wide")
        // The longest choice everywhere there is one to make.
        model.editTheme { look in
            look.setFollowsLamps(true)
            look.menuMotion = .lamp
            for attention in SessionAttention.counted {
                look.setMarkMotion(.gradient, fadeTo: .white, cycle: 2, for: attention)
            }
        }
        let hosting = NSHostingView(rootView: ThemeEditorPane(model: model).formStyle(.grouped))
        hosting.frame = NSRect(x: 0, y: 0, width: 570, height: 2600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI fills a form in over a few turns of the run loop, and widens the view only then.
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        // Content wider than it is given widens the view to fit rather than wrapping.
        XCTAssertEqual(hosting.frame.width, 570, "the editor needs \(hosting.frame.width) points")
    }

    private func makeModel() throws -> (SettingsModel, ThemeStore) {
        let preferences = try isolatedPreferences()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchThemes.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let themes = ThemeStore(preferences: preferences, folder: folder) { try FileManager.default.removeItem(at: $0) }
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeStatusMenuHost()
        addTeardownBlock { _ = host }
        let model = SettingsModel(
            themes: themes, settings: settings, rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        return (model, themes)
    }
}
