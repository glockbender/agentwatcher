import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchApp

/// The half of updating that sits between the network and the decision: what one answer from
/// GitHub means. The decision itself is `AppUpdate`'s and tested there; this is about the
/// status codes it never sees.
@MainActor
final class AppUpdaterTests: XCTestCase {
    func testMalformedSuccessfulResponsesAreFailedChecks() async {
        for body in ["<html>proxy error</html>", #"{"tag_name":"#, #"{"tag_name":"v0.2.0"}"#] {
            let decision = await AppUpdater.fetchDecision(
                ownVersion: "0.1.0",
                skippedVersion: nil,
                transport: answering(status: 200, body: body)
            )
            XCTAssertNil(decision, body)
        }
    }

    func testDisablingLaunchChecksCancelsThePendingRequest() async throws {
        let calls = RequestCount()
        let updater = AppUpdater(
            preferences: try isolatedPreferences(), bundleURL: try versionedBundle(),
            transport: { request in
                await calls.increment()
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let pending = try XCTUnwrap(updater.checkAfterLaunch(after: .seconds(60)))
        await Task.yield()
        updater.checksOnLaunch = false
        await pending.value

        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    func testAnEnabledLaunchCheckMakesOneRequest() async throws {
        let calls = RequestCount()
        let updater = AppUpdater(
            preferences: try isolatedPreferences(), bundleURL: try versionedBundle(),
            transport: { request in
                await calls.increment()
                return (
                    Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        await updater.checkAfterLaunch(after: .zero)?.value

        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    private actor RequestCount {
        var value = 0
        func increment() { value += 1 }
    }

    private func versionedBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-\(UUID()).app")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "0.1.0"], format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return directory
    }

    /// `/releases/latest` answers 404 while every release is a pre-release — the state this
    /// project has been in from the start. That is "nothing finished yet", not "GitHub could
    /// not be reached", and a person asking by hand must be told the first and not the second.
    func testNoFinishedReleaseIsUpToDateNotAFailedCheck() async {
        let decision = await AppUpdater.fetchDecision(
            ownVersion: "0.1.0",
            skippedVersion: nil,
            transport: answering(status: 404, body: #"{"message":"Not Found"}"#)
        )

        XCTAssertEqual(decision, .upToDate)
    }

    func testAnyOtherFailureIsAFailedCheck() async {
        let serverError = await AppUpdater.fetchDecision(
            ownVersion: "0.1.0",
            skippedVersion: nil,
            transport: answering(status: 500, body: "")
        )
        let noNetwork = await AppUpdater.fetchDecision(
            ownVersion: "0.1.0",
            skippedVersion: nil,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )

        XCTAssertNil(serverError)
        XCTAssertNil(noNetwork)
    }

    func testAFinishedReleaseIsDecidedOn() async {
        let decision = await AppUpdater.fetchDecision(
            ownVersion: "0.1.0",
            skippedVersion: nil,
            transport: answering(
                status: 200,
                body: """
                    {"tag_name": "v0.2.0", "html_url": "https://example.com/r", "assets": []}
                    """
            )
        )

        let page = URL(string: "https://example.com/r")!
        XCTAssertEqual(
            decision,
            .available(AppRelease(version: "0.2.0", pageURL: page, downloadURL: nil, checksumURL: nil))
        )
    }

    /// The new copy is opened by a shell that outlives this process, and it has to wait for
    /// this process to be gone — not for two seconds. A copy opened while the old one still
    /// holds the lock finds it, asks it to show itself, and exits: nothing left running, right
    /// after an update that worked.
    func testTheRelaunchWaitsForThisProcessToExitBeforeOpeningTheNewCopy() {
        let script = AppUpdater.relaunchScript(processID: 4242, bundlePath: "/Applications/Agent Watch.app")

        XCTAssertEqual(
            script,
            "while kill -0 4242 2>/dev/null; do sleep 0.2; done; open '/Applications/Agent Watch.app'"
        )
    }

    private func answering(status: Int, body: String) -> AppUpdater.Transport {
        { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}
