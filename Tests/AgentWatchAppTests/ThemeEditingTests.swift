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
        XCTAssertEqual(
            hosting.frame.width, 570,
            "the editor needs \(hosting.frame.width) points; fitting \(hosting.fittingSize)")
    }

    /// A change that changes nothing — Return in the name field, the colour a well already
    /// shows — leaves the built-in theme uncopied and says nothing is wrong.
    func testAChangeThatChangesNothingCopiesNothing() throws {
        let (model, themes) = try makeModel()

        model.changeTheme { $0.name = WidgetTheme.standard.name }
        model.editTheme { $0.setBackground(NSColor(sRGB: $0.background)) }

        XCTAssertEqual(themes.theme, .standard)
        XCTAssertEqual(themes.themes, [.standard])
        XCTAssertNil(model.themeProblem)
    }

    /// Into both looks, a change to one thing about a state's mark keeps what else each look
    /// has: the light look's fade is not the dark look's.
    func testAChangeToBothLooksKeepsWhatEachLookHasOfItsOwn() throws {
        let (model, themes) = try makeModel()
        model.themeScope = .light
        model.editTheme {
            $0.setMarkMotion(.gradient, fadeTo: NSColor(sRGB: "#112233"), cycle: 3, for: .working)
            $0.changeLampStyle(for: .executing) { $0.gradientColor = NSColor(sRGB: "#445566") }
        }
        model.themeScope = .both

        model.editTheme {
            $0.changeMarkStyle(for: .working) { $0.animationCycle = 6 }
            $0.changeLampStyle(for: .executing) { $0.animationCycle = 7 }
        }

        let light = themes.theme.light
        let dark = themes.theme.dark
        XCTAssertEqual(light.markStyle(for: .working, phases: [:]).animationCycle, 6)
        XCTAssertEqual(dark.markStyle(for: .working, phases: [:]).animationCycle, 6)
        XCTAssertEqual(light.markStyle(for: .working, phases: [:]).gradientColor.srgbHex, "#112233")
        XCTAssertEqual(light.markStyle(for: .working, phases: [:]).motion, .gradient)
        XCTAssertEqual(
            dark.markStyle(for: .working, phases: [:]).motion,
            WidgetTheme.standard.dark.markStyle(for: .working, phases: [:]).motion)
        XCTAssertEqual(light.lampScheme.style(for: .executing).gradientColor.srgbHex, "#445566")
        XCTAssertEqual(
            dark.lampScheme.style(for: .executing).gradientColor.srgbHex,
            WidgetTheme.standard.dark.lampScheme.style(for: .executing).gradientColor.srgbHex)
    }

    /// However far the slider goes, the widget stays findable: an opacity of nothing would be a
    /// widget nobody can see to put back.
    func testTheOpacityCannotReachInvisible() throws {
        let (model, themes) = try makeModel()

        model.editTheme { $0.widgetOpacity = 0 }

        XCTAssertGreaterThan(WidgetTheme.opacityRange.lowerBound, 0)
        XCTAssertEqual(themes.theme.dark.widgetOpacity, CGFloat(WidgetTheme.opacityRange.lowerBound), accuracy: 0.0001)
    }

    /// A colour chosen on one lamp's row changes that phase alone; Restore Default Lamps puts
    /// every row back.
    func testALampChangesAloneAndTheResetPutsEveryLampBack() throws {
        let (model, themes) = try makeModel()

        model.editTheme {
            $0.changeLampStyle(for: .executing) { $0.color = NSColor(sRGB: "#123456") }
            $0.changeLampStyle(for: .failed) { $0.motion = .steady }
        }

        let look = themes.theme.dark
        XCTAssertEqual(look.lampScheme.style(for: .executing).color.srgbHex, "#123456")
        XCTAssertEqual(look.lampScheme.style(for: .failed).motion, .steady)
        for phase in SessionPhase.allCases where phase != .executing && phase != .failed {
            XCTAssertEqual(look.lampScheme.style(for: phase), phase.defaultLampStyle, "\(phase)")
        }

        model.editTheme { $0.restoreDefaultLamps() }

        XCTAssertTrue(themes.theme.dark.lampScheme.isDefault)
        XCTAssertTrue(themes.theme.light.lampScheme.isDefault)
    }

    /// A file dropped into the folder, or a theme in use corrected there, is read when a page
    /// that shows themes opens — and the widget is told when the theme in use changed.
    func testAPageThatShowsThemesReadsTheFolderAgain() throws {
        let (model, themes) = try makeModel()
        try themes.create(named: "Mine")
        let folder = try XCTUnwrap(themes.folder)
        var told = 0
        themes.onChange = { _ in told += 1 }
        try Data(##"{"name": "Dropped", "dark": {"background": "#112233"}}"##.utf8)
            .write(to: folder.appendingPathComponent("Dropped.json"))
        try Data(##"{"name": "Mine", "dark": {"background": "#445566"}}"##.utf8)
            .write(to: folder.appendingPathComponent("Mine.json"))
        XCTAssertFalse(themes.themes.map(\.name).contains("Dropped"), "not read before a page asks")

        model.go(.themes)

        XCTAssertTrue(themes.themes.map(\.name).contains("Dropped"))
        XCTAssertEqual(themes.theme.dark.background, "#445566")
        XCTAssertEqual(told, 1)

        model.go(.general)
        model.go(.appearance)
        XCTAssertEqual(told, 1, "read again, and nothing in use changed")
    }

    private func makeModel() throws -> (SettingsModel, ThemeStore) {
        let preferences = try isolatedPreferences()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchThemes.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let themes = ThemeStore(preferences: preferences, folder: folder) { try FileManager.default.removeItem(at: $0) }
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        let model = SettingsModel(
            themes: themes, settings: settings, rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        return (model, themes)
    }
}
