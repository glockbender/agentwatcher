import XCTest

@testable import AgentWatchCore

final class AppUpdateTests: XCTestCase {
    /// Trimmed from the real answer of
    /// `https://api.github.com/repos/glockbender/agentwatcher/releases`, keeping every field
    /// this reads and the plugin asset that must not be mistaken for the app.
    private let apiAnswer = """
        [
          {
            "tag_name": "v0.1.0",
            "draft": false,
            "prerelease": true,
            "html_url": "https://github.com/glockbender/agentwatcher/releases/tag/v0.1.0",
            "assets": [
              {
                "name": "agent-watch-ide-0.1.3.zip",
                "browser_download_url": "https://github.com/glockbender/agentwatcher/releases/download/v0.1.0/agent-watch-ide-0.1.3.zip"
              },
              {
                "name": "AgentWatch-0.1.0.zip",
                "browser_download_url": "https://github.com/glockbender/agentwatcher/releases/download/v0.1.0/AgentWatch-0.1.0.zip"
              },
              {
                "name": "AgentWatch-0.1.0.zip.sha256",
                "browser_download_url": "https://github.com/glockbender/agentwatcher/releases/download/v0.1.0/AgentWatch-0.1.0.zip.sha256"
              }
            ]
          }
        ]
        """

    func testAReleaseIsReadWithBothOfItsFiles() {
        let releases = AppUpdate.releases(from: Data(apiAnswer.utf8))

        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.version, "0.1.0")
        XCTAssertEqual(
            releases.first?.pageURL.absoluteString,
            "https://github.com/glockbender/agentwatcher/releases/tag/v0.1.0"
        )
        XCTAssertEqual(
            releases.first?.downloadURL?.lastPathComponent,
            "AgentWatch-0.1.0.zip"
        )
        XCTAssertEqual(
            releases.first?.checksumURL?.lastPathComponent,
            "AgentWatch-0.1.0.zip.sha256"
        )
    }

    /// The plugin ships in the same release and carries its own version, so a rule like "the
    /// first zip" would hand the app a plugin to install over itself.
    func testThePluginInTheSameReleaseIsNotTakenForTheApp() {
        let releases = AppUpdate.releases(from: Data(apiAnswer.utf8))

        XCTAssertFalse(releases.first?.downloadURL?.lastPathComponent.contains("ide") ?? true)
    }

    func testADraftIsNotOffered() {
        let answer = """
            [{"tag_name": "v0.3.0", "draft": true, "html_url": "https://example.com/r", "assets": []}]
            """

        XCTAssertTrue(AppUpdate.releases(from: Data(answer.utf8)).isEmpty)
    }

    func testAnAnswerThatIsNotJSONLeavesNothingRatherThanFailing() {
        XCTAssertTrue(AppUpdate.releases(from: Data("not json at all".utf8)).isEmpty)
    }

    func testARunningBuildWithNoVersionIsNeverToldToUpdate() {
        let decision = AppUpdate.decide(
            ownVersion: nil,
            releases: [release("9.9.9")],
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .ownVersionUnknown)
    }

    func testTheSameVersionIsUpToDate() {
        let decision = AppUpdate.decide(
            ownVersion: "0.1.0",
            releases: [release("0.1.0")],
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .upToDate)
    }

    func testAnOlderPublishedBuildIsNotAnUpdate() {
        let decision = AppUpdate.decide(
            ownVersion: "0.2.0",
            releases: [release("0.1.0")],
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .upToDate)
    }

    func testANewerBuildIsOffered() {
        let decision = AppUpdate.decide(
            ownVersion: "0.1.0",
            releases: [release("0.2.0")],
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .available(release("0.2.0")))
    }

    /// Set aside means this version and only this version: the next one asks again.
    func testAVersionSetAsideIsNotOfferedAndTheNextOneStillIs() {
        let setAside = AppUpdate.decide(
            ownVersion: "0.1.0",
            releases: [release("0.2.0")],
            skippedVersion: "0.2.0"
        )
        let theOneAfter = AppUpdate.decide(
            ownVersion: "0.1.0",
            releases: [release("0.3.0")],
            skippedVersion: "0.2.0"
        )

        XCTAssertEqual(setAside, .skipped(release("0.2.0")))
        XCTAssertEqual(theOneAfter, .available(release("0.3.0")))
    }

    /// GitHub returns releases by creation time, and the newest one created is not always the
    /// highest version — a fix published for an older line is created last and is older.
    func testTheHighestVersionWinsRatherThanTheFirstInTheList() {
        let decision = AppUpdate.decide(
            ownVersion: "0.1.0",
            releases: [release("0.1.1"), release("0.3.0"), release("0.2.0")],
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .available(release("0.3.0")))
    }

    func testNoReleasesAtAllIsUpToDateRatherThanAnError() {
        let decision = AppUpdate.decide(ownVersion: "0.1.0", releases: [], skippedVersion: nil)

        XCTAssertEqual(decision, .upToDate)
    }

    func testTheChecksumIsReadOutOfTheFileShasumWrites() {
        let file = "10daea1f79a56e8b9ee5773ea61ebeaf43668fce5c167579a98e853881604d78  AgentWatch-0.1.0.zip\n"

        XCTAssertEqual(
            AppUpdate.checksum(fromChecksumFile: file),
            "10daea1f79a56e8b9ee5773ea61ebeaf43668fce5c167579a98e853881604d78"
        )
    }

    func testSomethingThatIsNotAChecksumIsRefused() {
        XCTAssertNil(AppUpdate.checksum(fromChecksumFile: "404: Not Found"))
        XCTAssertNil(AppUpdate.checksum(fromChecksumFile: ""))
        XCTAssertNil(AppUpdate.checksum(fromChecksumFile: "zzz  AgentWatch-0.1.0.zip"))
    }

    /// The reason the comparison is not string order, in one line.
    func testATenthPatchIsNewerThanANinth() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.9", than: "0.1.10"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.0", than: "0.1.0"))
    }

    private func release(_ version: String) -> AppRelease {
        AppRelease(
            version: version,
            pageURL: URL(string: "https://example.com/releases/tag/v\(version)")!,
            downloadURL: URL(string: "https://example.com/AgentWatch-\(version).zip")!,
            checksumURL: URL(string: "https://example.com/AgentWatch-\(version).zip.sha256")!
        )
    }
}
