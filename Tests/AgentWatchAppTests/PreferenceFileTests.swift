import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchApp

final class PreferenceFileTests: XCTestCase {
    func testHasNoValueBeforeAnythingIsWritten() throws {
        let preferences = PreferenceFile(directoryURL: try makeDirectory())

        XCTAssertNil(preferences.string(forKey: "widgetBackground"))
        XCTAssertNil(preferences.number(forKey: "widgetBackgroundOpacity"))
        XCTAssertNil(preferences.flag(forKey: "lockWidgetSize"))
    }

    func testAValueSurvivesIntoTheNextLaunch() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)

        preferences.set("slate", forKey: "widgetBackground")
        preferences.set(0.54, forKey: "widgetBackgroundOpacity")
        preferences.set(true, forKey: "lockWidgetSize")

        let reopened = PreferenceFile(directoryURL: directory)
        XCTAssertEqual(reopened.string(forKey: "widgetBackground"), "slate")
        XCTAssertEqual(reopened.number(forKey: "widgetBackgroundOpacity"), 0.54)
        XCTAssertEqual(reopened.flag(forKey: "lockWidgetSize"), true)
    }

    /// `README.md` invites a person to edit this file. A file the app cannot read was read as
    /// empty, and the next write — the defaults, at launch — went straight over it: the whole
    /// lamp scheme gone for a typo, or for a write that was cut short. Kept aside instead, the
    /// way the tooling installer keeps a file it is about to change.
    func testAFileThatCannotBeReadIsKeptAsideRatherThanOverwritten() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("settings.json")
        let broken = #"{"widgetBackground": "slate", "lockWidgetSize": tru"#
        try broken.write(to: fileURL, atomically: true, encoding: .utf8)

        let preferences = PreferenceFile(directoryURL: directory)
        XCTAssertNil(preferences.string(forKey: "widgetBackground"), "unreadable is not a value")
        preferences.set("graphite", forKey: "widgetBackground")

        let kept = try XCTUnwrap(preferences.unreadableFileKeptAt, "the person's own file has to survive")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), broken)
        XCTAssertEqual(PreferenceFile(directoryURL: directory).string(forKey: "widgetBackground"), "graphite")
    }

    /// A file that is simply not there is not a file anybody wrote, so nothing is kept aside.
    func testAMissingFileIsNotKeptAside() throws {
        let preferences = PreferenceFile(directoryURL: try makeDirectory())

        preferences.set("slate", forKey: "widgetBackground")

        XCTAssertNil(preferences.unreadableFileKeptAt)
    }

    /// The one thing about the format that cannot be settled by reading the code: whether a
    /// number comes back as a flag. `false` and `0` mean the same thing to a property list
    /// and different things here, and a setting that reads `0` as "off" by accident would be
    /// right until the day someone stored a zero that meant zero.
    func testAValueKeepsItsKindRatherThanItsShape() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)

        preferences.set(0, forKey: "aNumber")
        preferences.set(false, forKey: "aFlag")

        let reopened = PreferenceFile(directoryURL: directory)
        XCTAssertEqual(reopened.number(forKey: "aNumber"), 0)
        XCTAssertNil(reopened.flag(forKey: "aNumber"), "a stored number is not a flag")
        XCTAssertEqual(reopened.flag(forKey: "aFlag"), false)
        XCTAssertNil(reopened.number(forKey: "aFlag"), "a stored flag is not a number")
    }

    func testAnUnreadableFileReadsAsEmptyAndIsWrittenOverRatherThanKept() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("settings.json")
        try Data("this is not the file we left".utf8).write(to: fileURL)

        let preferences = PreferenceFile(directoryURL: directory)
        XCTAssertNil(preferences.string(forKey: "widgetBackground"))

        preferences.set("mint", forKey: "widgetBackground")
        XCTAssertEqual(PreferenceFile(directoryURL: directory).string(forKey: "widgetBackground"), "mint")
    }

    func testWritesIntoAFolderThatDoesNotExistYet() throws {
        let directory = try makeDirectory().appendingPathComponent("not-created-yet", isDirectory: true)
        let preferences = PreferenceFile(directoryURL: directory)

        preferences.set("mint", forKey: "widgetBackground")

        XCTAssertEqual(PreferenceFile(directoryURL: directory).string(forKey: "widgetBackground"), "mint")
    }

    func testAForgottenValueStaysForgotten() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)
        preferences.set(298, forKey: "widgetWidth")

        preferences.removeValue(forKey: "widgetWidth")

        XCTAssertNil(PreferenceFile(directoryURL: directory).number(forKey: "widgetWidth"))
    }

    /// Why the app builds exactly one of these and hands it round.
    ///
    /// Each write puts the whole document on disk from the instance's own copy of it, so two
    /// instances over one file each hold a copy that the other's writes do not reach — and
    /// the second write to land erases the first. The stores are given the file rather than
    /// making their own so that cannot be arranged by accident.
    func testStoresSharingOneFileKeepEachOthersValues() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)

        WidgetBackgroundStore(preferences: preferences).select(.mint)
        WidgetSettingsStore(preferences: preferences).setShowsSessionTopic(false)

        let reopened = PreferenceFile(directoryURL: directory)
        XCTAssertEqual(WidgetBackgroundStore(preferences: reopened).selected, .mint)
        XCTAssertFalse(WidgetSettingsStore(preferences: reopened).showsSessionTopic)
    }

    func testSeedingFillsOnlyWhatIsMissing() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)
        preferences.set("slate", forKey: "widgetBackground")

        preferences.seed([
            "widgetBackground": .string("graphite"),
            "widgetBackgroundOpacity": .number(0.96),
            "lockWidgetSize": .bool(false),
        ])

        let reopened = PreferenceFile(directoryURL: directory)
        XCTAssertEqual(reopened.string(forKey: "widgetBackground"), "slate", "a choice already made stands")
        XCTAssertEqual(reopened.number(forKey: "widgetBackgroundOpacity"), 0.96)
        XCTAssertEqual(reopened.flag(forKey: "lockWidgetSize"), false)
    }

    /// Seeding runs at every launch, so running it again must be a no-op — including for a
    /// value a person has since set back to what the default happens to be.
    func testSeedingTwiceChangesNothingTheSecondTime() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)
        let defaults: [String: JSONValue] = ["widgetBackgroundOpacity": .number(0.96)]

        preferences.seed(defaults)
        preferences.set(0.4, forKey: "widgetBackgroundOpacity")
        preferences.seed(defaults)

        XCTAssertEqual(PreferenceFile(directoryURL: directory).number(forKey: "widgetBackgroundOpacity"), 0.4)
    }

    func testReplacingOverwritesWhateverIsThere() throws {
        let directory = try makeDirectory()
        let preferences = PreferenceFile(directoryURL: directory)
        preferences.set(0.4, forKey: "widgetBackgroundOpacity")

        preferences.replace(["widgetBackgroundOpacity": .number(0.96)])

        XCTAssertEqual(PreferenceFile(directoryURL: directory).number(forKey: "widgetBackgroundOpacity"), 0.96)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchPreferenceTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
