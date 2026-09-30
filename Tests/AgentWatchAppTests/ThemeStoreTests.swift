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
    /// Anything a file leaves out is the built-in theme's, in the same mode, so a theme that
    /// names a single colour is a theme, not an error.
    func testAThemeFileMissingFieldsIsReadWithTheDefaults() throws {
        let folder = try themesFolder()
        try write(##"{"name": "Sparse", "light": {}, "dark": {"background": "#112233"}}"##, to: folder, as: "Sparse")

        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        XCTAssertEqual(store.problems, [])
        let sparse = try XCTUnwrap(store.themes.first { $0.name == "Sparse" })
        XCTAssertEqual(sparse.dark.widgetBackground.color.srgbHex, "#112233")
        XCTAssertEqual(sparse.light, WidgetTheme.standard.light, "an empty look is the built-in light one")
        XCTAssertTrue(sparse.dark.lampScheme.isDefault)
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

    /// A value of the wrong kind is not guessed at: the file is not read, and is named with what
    /// was wrong. A lamp is one value, so a lamp missing a field is one of those.
    func testAFileWithAValueOfTheWrongKindIsReportedRatherThanGuessedAt() throws {
        let folder = try themesFolder()
        try write(##"{"name": "Typed", "dark": {"opacity": "half"}}"##, to: folder, as: "Typed")
        try write(
            ##"{"name": "Lamp", "dark": {"lamps": {"executing": {"color": "#FF0000"}}}}"##, to: folder, as: "Lamp")

        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        XCTAssertEqual(store.themes, [.standard])
        XCTAssertEqual(store.problems.map { String($0.prefix(while: { $0 != ":" })) }, ["Lamp.json", "Typed.json"])
    }

    /// Duplicating is how editing starts: the copy is a file of its own, selected, with a name
    /// that does not collide with one already on offer.
    func testDuplicateWritesACopyAndSelectsIt() throws {
        let folder = try themesFolder()
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        try store.duplicate(store.theme)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Default copy.json"])
        XCTAssertEqual(store.theme.name, "Default copy")
        XCTAssertEqual(store.theme.dark, WidgetTheme.standard.dark)

        try store.duplicate(.standard)

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

    // MARK: - What a file written before a field existed reads as

    /// A file with none of the panel's, the states' motion, the menu's or the sphere's fields
    /// draws them as the built-in theme does.
    func testAFileWithoutTheLaterFieldsDrawsThemAsTheBuiltInThemeDoes() throws {
        let older = ##"""
            {"name": "Mine", "dark": {"background": "#006996",
              "attention": {"done": "#30D159", "needsPerson": "#FF9F0A", "quiet": "#9E9E9E", "working": "#0A85FF"},
              "colors": {"highlight": "#FF9F0A", "timerQuiet": "#FFD60A", "timerStale": "#FF9F0A"},
              "lamps": {"executing": {"color": "#00FF5C", "cycle": 2.5, "fadeTo": "#00A900", "motion": "dim"}}},
             "light": {}}
            """##
        let look = try ThemeStore.decode(Data(older.utf8)).dark

        XCTAssertEqual(look.widgetMaterial, .glass)
        XCTAssertEqual(look.widgetOpacity, CGFloat(WidgetTheme.defaultOpacity))
        XCTAssertEqual(look.accent(for: .working).srgbHex, "#0A85FF", "a state keeps its own colour")
        XCTAssertEqual(look.sphereMotion, WidgetTheme.Sphere())
        // The grid as it shipped: the two states a person acts on breathe, at 1.4 s.
        for attention in [SessionAttention.needsPerson, .working] {
            XCTAssertEqual(look.markStyle(for: attention).motion, .dim, attention.rawValue)
            XCTAssertEqual(look.markStyle(for: attention).animationCycle, 1.4, attention.rawValue)
        }
        XCTAssertEqual(look.markStyle(for: .done).motion, .steady)
        // And the menu's marks hold still in the state's colour.
        let line = look.menuMarkStyle(for: .executing)
        XCTAssertEqual(line.motion, .steady)
        XCTAssertEqual(line.color.srgbHex, "#0A85FF")
    }

    // MARK: - States that take a lamp's colour

    /// Eleven lamps and four states: a state can take the colour of one of its own phases'
    /// lamps, and only those — waiting for you can stand for needs you, working cannot.
    func testAStateTakesItsColourOnlyFromALampOfItsOwn() throws {
        var look = WidgetTheme.standard.dark
        look.setLamp(.failed, for: .needsPerson)
        XCTAssertEqual(look.accent(for: .needsPerson), look.lampScheme.style(for: .failed).color)
        XCTAssertEqual(look.ownAccent(for: .needsPerson).srgbHex, "#FF9F0A", "its own colour is kept for later")

        look.setLamp(.executing, for: .needsPerson)
        XCTAssertNil(look.lamp(for: .needsPerson), "a lamp of another state is refused")

        // A file may say anything; a phase of another state reads as the state's own colour.
        look.attentionLamps[SessionAttention.done.rawValue] = SessionPhase.executing.rawValue
        XCTAssertEqual(look.accent(for: .done).srgbHex, "#30D159")
    }

    /// The one switch for a person who wants everything to match: every state shown in the
    /// menu bar takes its lead lamp, and every menu line its own session's lamp.
    func testFollowingTheLampsMatchesTheMenuBarAndTheMenuToThem() throws {
        var look = WidgetTheme.standard.dark
        XCTAssertFalse(look.followsLamps)

        look.setFollowsLamps(true)

        XCTAssertTrue(look.followsLamps)
        XCTAssertEqual(look.lamp(for: .working), .executing)
        XCTAssertEqual(look.accent(for: .working), look.lampScheme.style(for: .executing).color)
        XCTAssertEqual(look.menuMarkStyle(for: .failed).color, look.lampScheme.style(for: .failed).color)

        look.setFollowsLamps(false)

        XCTAssertNil(look.lamp(for: .working))
        XCTAssertEqual(look.accent(for: .working).srgbHex, "#0A85FF")
    }

    /// A lead lamp chosen by hand survives the switch being turned on over it.
    func testTurningEverythingToTheLampsKeepsALeadLampChosenBefore() {
        var look = WidgetTheme.standard.dark
        look.setLamp(.failed, for: .needsPerson)

        look.setFollowsLamps(true)

        XCTAssertEqual(look.lamp(for: .needsPerson), .failed)
    }

    /// The owner's case: nineteen sessions with no signal and none idle. A state told to take
    /// the lamp most of its sessions are in shows the no-signal lamp, as the widget's rows do.
    func testAStateCanTakeTheLampMostOfItsSessionsAreIn() {
        var look = WidgetTheme.standard.dark
        look.setColourSource(.mostSessions, for: .quiet)

        let noSignal: [SessionPhase: Int] = [.disconnected: 19, .idle: 2, .executing: 3]
        XCTAssertEqual(look.lamp(for: .quiet, phases: noSignal), .disconnected)
        XCTAssertEqual(look.accent(for: .quiet, phases: noSignal), look.lampScheme.style(for: .disconnected).color)

        let waiting: [SessionPhase: Int] = [.waitingForUser: 2, .failed: 1]
        look.setColourSource(.mostSessions, for: .needsPerson)
        XCTAssertEqual(look.lamp(for: .needsPerson, phases: waiting), .waitingForUser)
    }

    /// A tie goes to the state's lead lamp, and so does a state with no sessions at all.
    func testATieOrNoSessionsGoesToTheLeadLamp() {
        var look = WidgetTheme.standard.dark
        look.setColourSource(.mostSessions, for: .quiet)

        XCTAssertEqual(look.lamp(for: .quiet, phases: [.idle: 2, .disconnected: 2]), .idle)
        XCTAssertEqual(look.lamp(for: .quiet, phases: [.rateLimited: 1, .disconnected: 1]), .rateLimited)
        XCTAssertEqual(look.lamp(for: .quiet, phases: [:]), .idle)
    }

    /// Matching everything to the lamps now means each state follows most of its sessions,
    /// and the choice is kept in the file under a name of its own.
    func testMatchingToTheLampsFollowsMostSessionsAndIsKeptInTheFile() throws {
        var theme = WidgetTheme.standard
        theme.dark.setFollowsLamps(true)

        XCTAssertEqual(theme.dark.colourSource(for: .quiet), .mostSessions)
        XCTAssertTrue(theme.dark.dependsOnSessionPhases)
        let reread = try ThemeStore.decode(ThemeStore.encode(theme))
        XCTAssertEqual(reread.dark.colourSource(for: .quiet), .mostSessions)
        XCTAssertEqual(reread.dark.attentionLamps[SessionAttention.quiet.rawValue], "mostSessions")
        XCTAssertFalse(WidgetTheme.standard.dark.dependsOnSessionPhases)
    }

    /// A menu line moves like its session's lamp when told to, and like its state otherwise.
    func testAMenuLineMovesLikeWhatTheThemeSays() {
        var look = WidgetTheme.standard.dark
        look.menuMotion = .lamp
        let waiting = look.menuMarkStyle(for: .waitingForUser)
        XCTAssertEqual(waiting.motion, .gradient)
        XCTAssertEqual(waiting.animationCycle, 0.5)

        look.menuMotion = .state
        XCTAssertEqual(look.menuMarkStyle(for: .waitingForUser).motion, .dim)
        XCTAssertEqual(look.menuMarkStyle(for: .waitingForUser).animationCycle, 1.4)
    }

    // MARK: - Making, changing and removing themes

    /// The built-in theme lives in the code and is never written; the first change to it is
    /// made to a copy, which is then the theme in use.
    func testEditingTheBuiltInThemeMakesACopyFirst() throws {
        let folder = try themesFolder()
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)

        let copy = try store.editable()

        XCTAssertEqual(copy.name, "Default copy")
        XCTAssertEqual(store.theme.name, "Default copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Default copy.json").path))
        XCTAssertEqual(try store.editable().name, "Default copy", "a file is its own copy")
        XCTAssertThrowsError(try store.save(.standard, replacing: WidgetTheme.standard.name))
    }

    /// A save writes the file over, follows a new name onto a new file, and tells the widget
    /// only when the theme on screen changed — and only when something did.
    func testSavingWritesTheFileAndFollowsARename() throws {
        let folder = try themesFolder()
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder)
        var theme = try store.create(named: "Mine")
        var changes = 0
        store.onChange = { _ in changes += 1 }

        try store.save(theme, replacing: "Mine")
        XCTAssertEqual(changes, 0, "nothing changed, so nothing was written")

        theme.dark.widgetOpacity = 0.5
        theme.name = "Renamed"
        try store.save(theme, replacing: "Mine")

        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.theme.name, "Renamed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mine.json").path))
        let reread = ThemeStore(preferences: try isolatedPreferences(), folder: folder)
        XCTAssertEqual(reread.themes.first { $0.name == "Renamed" }?.dark.widgetOpacity, 0.5)
    }

    func testANameIsNeitherEmptyNorOneAlreadyTaken() throws {
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: try themesFolder())
        try store.create(named: "First")
        var second = try store.create(named: "Second")

        second.name = "First"
        XCTAssertThrowsError(try store.save(second, replacing: "Second")) {
            XCTAssertEqual($0 as? ThemeStore.Problem, .nameTaken("First"))
        }
        second.name = "  "
        XCTAssertThrowsError(try store.save(second, replacing: "Second")) {
            XCTAssertEqual($0 as? ThemeStore.Problem, .emptyName)
        }
        XCTAssertEqual(store.theme.name, "Second")
    }

    /// Deleting hands the file to the Trash — here, to the test — and the built-in theme takes
    /// over if the deleted one was on screen.
    func testDeletingHandsTheFileOverAndFallsBackToTheBuiltInTheme() throws {
        let folder = try themesFolder()
        var discarded: [String] = []
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: folder) { url in
            discarded.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        let mine = try store.create(named: "Mine")

        try store.delete(mine)

        XCTAssertEqual(discarded, ["Mine.json"])
        XCTAssertEqual(store.theme, .standard)
        XCTAssertEqual(store.customThemes, [])
        XCTAssertThrowsError(try store.delete(.standard))
    }

    /// An imported file joins the folder under a name nobody has, and is put in use. The
    /// built-in theme's name is never given away.
    func testImportingCopiesTheFileInUnderAFreeName() throws {
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: try themesFolder())
        let outside = try themesFolder()
        try write(##"{"name": "Shared", "dark": {"background": "#112233"}}"##, to: outside, as: "Shared")
        try write(##"{"name": "Default"}"##, to: outside, as: "Claims the default")

        let first = try store.importTheme(from: outside.appendingPathComponent("Shared.json"))
        let second = try store.importTheme(from: outside.appendingPathComponent("Shared.json"))
        let claimed = try store.importTheme(from: outside.appendingPathComponent("Claims the default.json"))

        XCTAssertEqual([first.name, second.name, claimed.name], ["Shared", "Shared 2", "Default (file)"])
        XCTAssertEqual(store.theme.name, "Default (file)")
        XCTAssertEqual(first.dark.background, "#112233")
    }

    func testAFileThatIsNotAThemeIsRefusedAndNothingIsAdded() throws {
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: try themesFolder())
        let outside = try themesFolder()
        try write("not a theme", to: outside, as: "Broken")

        XCTAssertThrowsError(try store.importTheme(from: outside.appendingPathComponent("Broken.json")))
        XCTAssertEqual(store.themes, [.standard])
    }

    /// What is exported is what imports back.
    func testAnExportedThemeImportsBackTheSame() throws {
        let store = ThemeStore(preferences: try isolatedPreferences(), folder: try themesFolder())
        var theme = try store.create(named: "Round trip")
        theme.dark.setFollowsLamps(true)
        theme.dark.sphere.swayDegrees = 20
        try store.save(theme, replacing: theme.name)
        let file = try themesFolder().appendingPathComponent("out.json")

        try store.export(theme, to: file)

        XCTAssertEqual(try ThemeStore.decode(Data(contentsOf: file)), theme)
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
