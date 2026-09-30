import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The parts list of the settings window's Row pane: one list in the order a person arranged
/// it, which a switch never reorders.
@MainActor
final class RowLayoutSectionTests: XCTestCase {
    func testEveryPartIsListedOnceWithTheRowsOwnFirst() {
        let listed = RowPartList.listed(for: .standard)

        XCTAssertEqual(Set(listed), Set(RowPart.allCases))
        XCTAssertEqual(listed.count, RowPart.allCases.count)
        XCTAssertEqual(Array(listed.prefix(RowLayout.standard.parts.count)), RowLayout.standard.parts)
    }

    /// A part switched off, dragged into place and switched on stands where it was dragged:
    /// the row keeps no place for a part it does not show, so the list the page shows does.
    func testSwitchingAPartOnPlacesItWhereItWasDragged() throws {
        let model = try makeModel()
        var listed = model.listedParts
        listed.removeAll { $0 == .branch }
        listed.insert(.branch, at: 1)

        model.reorderParts(listed)
        XCTAssertEqual(model.layout.parts, RowLayout.standard.parts, "a part switched off changes no row")
        XCTAssertEqual(model.listedParts[1], .branch, "and keeps the place it was dragged to")
        model.switchPart(.branch, on: true)

        XCTAssertEqual(model.layout.parts[1], .branch)
        XCTAssertEqual(model.layout.parts.filter { $0 != .branch }, RowLayout.standard.parts)
        XCTAssertEqual(model.listedParts[1], .branch)
    }

    func testMovingAPartEarlierIsStored() throws {
        let model = try makeModel()
        var listed = model.listedParts
        listed.removeAll { $0 == .context }
        listed.insert(.context, at: 0)

        model.reorderParts(listed)

        XCTAssertEqual(model.layout.parts.first, .context)
    }

    /// The gap has no switch — it is where the row's right end starts — but moves like a part.
    func testTheGapMovesButStaysInTheRow() throws {
        let model = try makeModel()
        var listed = model.listedParts
        listed.removeAll { $0 == .gap }
        listed.insert(.gap, at: 1)

        model.reorderParts(listed)

        XCTAssertEqual(model.layout.parts[1], .gap)
        XCTAssertTrue(model.layout.shows(.gap))
    }

    func testSwitchingACounterKindOffIsStored() throws {
        let model = try makeModel()
        let kind = try XCTUnwrap(model.layout.counterKinds.first)

        model.countActivity(kind, false)

        XCTAssertFalse(model.layout.counterKinds.contains(kind))
        model.countActivity(kind, true)
        XCTAssertTrue(model.layout.counterKinds.contains(kind))
    }

    /// A row changed from outside the page is read again; Restore Defaults puts the list back
    /// with it.
    func testTheListFollowsARowChangedElsewhere() throws {
        let model = try makeModel()
        model.rowLayouts.setLayout(RowLayout(parts: [.lamp, .gap, .timer]))
        model.refresh()

        XCTAssertEqual(Array(model.listedParts.prefix(3)), [.lamp, .gap, .timer])

        model.restoreRowDefaults()

        XCTAssertEqual(model.layout, .standard)
        XCTAssertEqual(model.listedParts, RowPartList.listed(for: .standard))
    }

    func testSwitchingAPartOffKeepsTheOthersInOrder() {
        let listed = RowPartList.listed(for: .standard)

        let parts = RowPartList.parts(from: listed, in: .standard, switching: .context, on: false)

        XCTAssertEqual(parts, RowLayout.standard.parts.filter { $0 != .context })
    }

    func testTheLastPartInTheRowCannotBeSwitchedOff() {
        let layout = RowLayout(parts: [.lamp, .gap])

        XCTAssertTrue(RowPartList.isLast(.lamp, in: layout))
        XCTAssertFalse(RowPartList.isLast(.lamp, in: .standard))
    }

    /// Said beside the switch, not only on hover: when the part appears, and for the last one,
    /// why its switch is greyed.
    func testEveryPartSaysWhenItAppearsAndTheLastSaysWhyItStays() {
        XCTAssertEqual(RowPartList.note(for: .branch, in: .standard), "only in a git repo")
        XCTAssertEqual(
            RowPartList.note(for: .lamp, in: RowLayout(parts: [.lamp, .gap])), "stays: a row has to draw something")
    }

    func testAVariantChoiceIsStoredForItsPartAlone() {
        let layout = RowPartText.layout(.standard, choosing: 1, for: .name)

        XCTAssertEqual(layout.nameStyle, .title)
        XCTAssertEqual(layout.modelStyle, RowLayout.standard.modelStyle)
        XCTAssertEqual(RowPartText.variantIndex(of: .name, in: layout), 1)
        XCTAssertEqual(RowPartText.layout(.standard, choosing: 2, for: .context).contextStyle, .both)
    }

    func testTheCounterMenuSaysHowManyKindsItCounts() {
        XCTAssertEqual(RowPartText.counterKindsTitle(Set(ActivityKind.allCases)), "All kinds")
        XCTAssertEqual(
            RowPartText.counterKindsTitle([.shell]), "1 of \(ActivityKind.allCases.count) kinds")
    }

    private func makeModel() throws -> SettingsModel {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        return SettingsModel(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
    }
}
