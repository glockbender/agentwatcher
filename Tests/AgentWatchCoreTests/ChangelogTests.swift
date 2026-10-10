import XCTest

@testable import AgentWatchCore

final class ChangelogTests: XCTestCase {
    private let file = """
        # Changelog

        What changed for somebody updating Agent Watch.

        ## [Unreleased]

        ### Changed

        - Something not released yet.

        ## [0.5.0] - 2026-11-01

        ### Added

        - Five.

        ## [0.4.0] - 2026-10-12

        ### Fixed

        - Four.

        ## [0.3.0] - 2026-10-08

        - Three.

        ## [0.1.0] - 2026-09-11

        First public build.
        """

    func testOneVersionBehindSeesOnlyTheOfferedSection() {
        let unseen = Changelog.unseen(in: file, installed: "0.4.0", offered: "0.5.0")

        XCTAssertEqual(unseen, "## [0.5.0] - 2026-11-01\n\n### Added\n\n- Five.")
    }

    func testASkippedReleaseIsShownUnderTheOfferedOneNewestFirst() {
        let unseen = Changelog.unseen(in: file, installed: "0.3.0", offered: "0.5.0") ?? ""

        XCTAssertTrue(unseen.hasPrefix("## [0.5.0]"))
        XCTAssertTrue(unseen.contains("## [0.4.0]"))
        XCTAssertFalse(unseen.contains("0.3.0"), "the running version is already known")
        XCTAssertLessThan(unseen.range(of: "Five")!.lowerBound, unseen.range(of: "Four")!.lowerBound)
    }

    func testNothingNewerThanTheOfferedVersionIsShown() {
        let unseen = Changelog.unseen(in: file, installed: "0.3.0", offered: "0.4.0")

        XCTAssertEqual(unseen, "## [0.4.0] - 2026-10-12\n\n### Fixed\n\n- Four.")
    }

    func testUnreleasedAndTheIntroductionAreNeverShown() {
        let unseen = Changelog.unseen(in: file, installed: "0.0.1", offered: "9.9.9") ?? ""

        XCTAssertFalse(unseen.contains("Unreleased"))
        XCTAssertFalse(unseen.contains("not released yet"))
        XCTAssertFalse(unseen.contains("What changed for somebody"))
        XCTAssertTrue(unseen.hasSuffix("First public build."))
    }

    func testVersionsCompareAsNumbersNotText() {
        let tenth = "## [0.1.10] - 2026-12-01\n\n- Ten.\n\n## [0.1.9] - 2026-11-01\n\n- Nine."

        XCTAssertEqual(
            Changelog.unseen(in: tenth, installed: "0.1.9", offered: "0.1.10"), "## [0.1.10] - 2026-12-01\n\n- Ten.")
    }

    /// Left as written, the second half of a wrapped bullet would stand in the window as a
    /// paragraph of its own, cut off mid-sentence.
    func testAWrappedBulletReadsAsOneLine() {
        let text = """
            ### Added

            - The update window lists what changed, with a progress bar and a
              Cancel button.
            - Short.
            """

        let joined = "- The update window lists what changed, with a progress bar and a Cancel button."

        XCTAssertEqual(Changelog.logicalLines(of: text), ["### Added", "", joined, "- Short."])
    }

    /// Only an indented line continues: a paragraph after a blank line and a new bullet stay apart.
    func testABlankLineOrANewBulletStartsAnewLine() {
        let text = "## [0.1.0] - 2026-09-11\n\nFirst public build.\n- One.\n- Two."

        XCTAssertEqual(
            Changelog.logicalLines(of: text),
            ["## [0.1.0] - 2026-09-11", "", "First public build.", "- One.", "- Two."])
    }

    /// The caller shows what it would have shown anyway, rather than an empty window.
    func testAFileWithNoMatchingSectionGivesNothing() {
        XCTAssertNil(Changelog.unseen(in: file, installed: "0.5.0", offered: "0.5.0"))
        XCTAssertNil(Changelog.unseen(in: "not a changelog at all", installed: "0.1.0", offered: "0.2.0"))
        XCTAssertNil(Changelog.unseen(in: "", installed: "0.1.0", offered: "0.2.0"))
    }
}
