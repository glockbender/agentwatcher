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

    func testSwitchingAPartOnPlacesItWhereItIsListed() {
        var listed = RowPartList.listed(for: .standard)
        listed.removeAll { $0 == .branch }
        listed.insert(.branch, at: 1)

        let parts = RowPartList.parts(from: listed, in: .standard, switching: .branch, on: true)

        XCTAssertEqual(parts[1], .branch)
        XCTAssertEqual(parts.filter { $0 != .branch }, RowLayout.standard.parts)
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
}
