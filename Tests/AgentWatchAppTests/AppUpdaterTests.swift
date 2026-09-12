import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchApp

/// The half of updating that sits between the network and the decision: what one answer from
/// GitHub means. The decision itself is `AppUpdate`'s and tested there; this is about the
/// status codes it never sees.
@MainActor
final class AppUpdaterTests: XCTestCase {
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
