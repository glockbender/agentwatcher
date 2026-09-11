import XCTest

@testable import AgentWatchCore

final class AppUpdateTests: XCTestCase {
    /// Trimmed from the real answer of
    /// `https://api.github.com/repos/glockbender/agentwatcher/releases/latest`, keeping every
    /// field this reads and the plugin asset that must not be mistaken for the app.
    private let apiAnswer = """
        {
            "tag_name": "v0.1.0",
            "draft": false,
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
        """

    func testAReleaseIsReadWithBothOfItsFiles() {
        let release = AppUpdate.release(from: Data(apiAnswer.utf8))

        XCTAssertEqual(release?.version, "0.1.0")
        XCTAssertEqual(
            release?.pageURL.absoluteString,
            "https://github.com/glockbender/agentwatcher/releases/tag/v0.1.0"
        )
        XCTAssertEqual(release?.downloadURL?.lastPathComponent, "AgentWatch-0.1.0.zip")
        XCTAssertEqual(release?.checksumURL?.lastPathComponent, "AgentWatch-0.1.0.zip.sha256")
    }

    /// The plugin ships in the same release and carries its own version, so a rule like "the
    /// first zip" would hand the app a plugin to install over itself.
    func testThePluginInTheSameReleaseIsNotTakenForTheApp() {
        let release = AppUpdate.release(from: Data(apiAnswer.utf8))

        XCTAssertFalse(release?.downloadURL?.lastPathComponent.contains("ide") ?? true)
    }

    func testADraftIsNotOffered() {
        let answer = """
            {"tag_name": "v0.3.0", "draft": true, "html_url": "https://example.com/r", "assets": []}
            """

        XCTAssertNil(AppUpdate.release(from: Data(answer.utf8)))
    }

    func testAnAnswerThatIsNotJSONLeavesNothingRatherThanFailing() {
        XCTAssertNil(AppUpdate.release(from: Data("not json at all".utf8)))
    }

    func testARunningBuildWithNoVersionIsNeverToldToUpdate() {
        let decision = AppUpdate.decide(
            ownVersion: nil,
            release: release("9.9.9"),
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .ownVersionUnknown)
    }

    func testTheSameVersionIsUpToDate() {
        let decision = AppUpdate.decide(
            ownVersion: "0.1.0",
            release: release("0.1.0"),
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .upToDate)
    }

    func testAnOlderPublishedBuildIsNotAnUpdate() {
        let decision = AppUpdate.decide(
            ownVersion: "0.2.0",
            release: release("0.1.0"),
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .upToDate)
    }

    func testANewerBuildIsOffered() {
        let decision = AppUpdate.decide(
            ownVersion: "0.1.0",
            release: release("0.2.0"),
            skippedVersion: nil
        )

        XCTAssertEqual(decision, .available(release("0.2.0")))
    }

    /// Set aside means this version and only this version: the next one asks again.
    func testAVersionSetAsideIsNotOfferedAndTheNextOneStillIs() {
        let setAside = AppUpdate.decide(
            ownVersion: "0.1.0",
            release: release("0.2.0"),
            skippedVersion: "0.2.0"
        )
        let theOneAfter = AppUpdate.decide(
            ownVersion: "0.1.0",
            release: release("0.3.0"),
            skippedVersion: "0.2.0"
        )

        XCTAssertEqual(setAside, .skipped(release("0.2.0")))
        XCTAssertEqual(theOneAfter, .available(release("0.3.0")))
    }

    /// Nothing finished has been published yet — every build so far is a pre-release, which
    /// this endpoint does not return. Not an error, and not something to tell a person about.
    func testNoFinishedReleaseYetIsUpToDateRatherThanAnError() {
        let decision = AppUpdate.decide(ownVersion: "0.1.0", release: nil, skippedVersion: nil)

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

    private func release(_ version: String) -> AppRelease {
        AppRelease(
            version: version,
            pageURL: URL(string: "https://example.com/releases/tag/v\(version)")!,
            downloadURL: URL(string: "https://example.com/AgentWatch-\(version).zip")!,
            checksumURL: URL(string: "https://example.com/AgentWatch-\(version).zip.sha256")!
        )
    }
}
