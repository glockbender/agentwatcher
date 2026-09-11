import Foundation
import XCTest

@testable import AgentWatchCore

/// What the installation section of the tooling window is allowed to claim about an IDE.
final class IDEPluginInstallationTests: XCTestCase {
    /// The sample is a real reply, copied from this machine.
    func testAReplyIsReadWithEverythingThePluginPutInIt() throws {
        let data = Data(
            """
            {"token":"nsw4k0bfzomrpl7o","pluginVersion":"0.1.2","ideBuild":"GO-261.26222.72",\
            "answeredAt":"2026-09-11T01:25:45.031277Z"}
            """.utf8
        )

        let reply = try XCTUnwrap(IDEPluginReply.parse(data))

        XCTAssertEqual(reply.token, "nsw4k0bfzomrpl7o")
        XCTAssertEqual(reply.pluginVersion, "0.1.2")
        XCTAssertEqual(reply.ideBuild, "GO-261.26222.72")
        XCTAssertNotNil(reply.answeredAt)
    }

    /// Java writes the fractional part only when it is not zero, so both shapes arrive from
    /// the same line of Kotlin — and one `ISO8601DateFormatter` reads only one of them.
    func testAnInstantWithoutFractionalSecondsIsStillADate() throws {
        let data = Data(#"{"token":"aaaabbbbcccc","answeredAt":"2026-09-11T01:25:45Z"}"#.utf8)

        let reply = try XCTUnwrap(IDEPluginReply.parse(data))

        XCTAssertNotNil(reply.answeredAt)
        XCTAssertNil(reply.pluginVersion, "a field the plugin did not write is absent, not empty")
    }

    /// The token is the whole point of the file. Without one there is nothing to compare, so
    /// there is no answer here — only bytes.
    func testAFileWithoutATokenIsNotAnAnswer() {
        XCTAssertNil(IDEPluginReply.parse(Data(#"{"pluginVersion":"0.1.3"}"#.utf8)))
        XCTAssertNil(IDEPluginReply.parse(Data("not json at all".utf8)))
    }

    /// An IDE nothing can address cannot be asked, so "the plugin has never answered" would
    /// be a claim about a question that was never put.
    func testAnIDEThatCannotBeAddressedIsSaidToBeThatRatherThanEmpty() {
        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: nil,
                isDaemonInstalled: true,
                reply: nil,
                check: .notAsked
            ),
            .unaddressable(.bundleNamesNoScheme)
        )
        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: false,
                reply: nil,
                check: .notAsked
            ),
            .unaddressable(.daemonMissing)
        )
    }

    /// The reply file outlives the plugin — nothing deletes it when the plugin is removed —
    /// so an old reply says "was loaded here", and only a fresh token says anything about now.
    func testAnOldReplyIsNeverReadAsAnAnswerToThisQuestion() {
        let reply = IDEPluginReply(token: "abcdefgh1234", pluginVersion: "0.1.2", ideBuild: nil, answeredAt: nil)

        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .notAsked
            ),
            .answeredEarlier(reply)
        )
        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .waiting(token: "somethingelse1")
            ),
            .checking,
            "the address is out and the answer has not come — not yet an answer either way"
        )
        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .done(token: "abcdefgh1234")
            ),
            .confirmed(reply)
        )
    }

    /// The state the whole check exists for: the file says the plugin was here, and it did
    /// not answer just now. A plugin that has been removed — or an IDE updated into a new
    /// settings directory — looks exactly like a working one until somebody asks.
    func testSilenceAfterAskingOutweighsAFileFromBefore() {
        let reply = IDEPluginReply(token: "abcdefgh1234", pluginVersion: "0.1.2", ideBuild: nil, answeredAt: nil)

        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .done(token: "zzzzzzzz9999")
            ),
            .askedAndSilent(reply)
        )
    }

    func testAnIDEThatHasNeverAnsweredIsSaidSoOnce() {
        XCTAssertEqual(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: nil,
                check: .notAsked
            ),
            .neverAnswered
        )
    }

    /// The directory may hold a release beside the one before it, and the name is where the
    /// version is — which is what lets a row say the IDE answered an older one.
    func testTheHighestVersionInTheDirectoryIsTheOneOffered() {
        let staged = IDEPluginInstallation.stagedPlugin(
            among: [
                "agent-watch-ide-0.1.9.zip",
                "agent-watch-ide-0.1.10.zip",
                "agent-watch-ide-0.1.3.zip",
                ".DS_Store",
                "something-else-2.0.zip",
            ]
        )

        XCTAssertEqual(staged, StagedIDEPlugin(fileName: "agent-watch-ide-0.1.10.zip", version: "0.1.10"))
    }

    func testAnEmptyDirectoryOffersNothing() {
        XCTAssertNil(IDEPluginInstallation.stagedPlugin(among: []))
        XCTAssertNil(IDEPluginInstallation.stagedPlugin(among: ["agent-watch-ide-.zip"]))
    }

    /// The plugin refuses anything that is not letters and digits, because any page in a
    /// browser can open a `jetbrains://` link. This is that rule, on this side.
    func testEveryTokenThisAppMakesIsOneThePluginWillAccept() {
        for _ in 0..<50 {
            XCTAssertTrue(IDEPluginInstallation.isAcceptableToken(IDEPluginInstallation.newToken()))
        }
        XCTAssertFalse(IDEPluginInstallation.isAcceptableToken("short"))
        XCTAssertFalse(IDEPluginInstallation.isAcceptableToken("has a space in it"))
        XCTAssertFalse(IDEPluginInstallation.isAcceptableToken(String(repeating: "a", count: 65)))
    }

    /// The scheme comes out of somebody else's application bundle and is pasted into a URL.
    func testOnlyARealSchemeAndARealTokenBecomeAnAddress() throws {
        let ping = try XCTUnwrap(IDEPluginInstallation.pingURL(productScheme: "goland", token: "abcdefgh1234"))
        XCTAssertEqual(ping.absoluteString, "jetbrains://goland/agent-watch/ping?token=abcdefgh1234")

        XCTAssertNil(IDEPluginInstallation.pingURL(productScheme: "go/land", token: "abcdefgh1234"))
        XCTAssertNil(IDEPluginInstallation.pingURL(productScheme: "goland", token: "no"))

        let page = try XCTUnwrap(IDEPluginInstallation.pluginsPageURL(productScheme: "idea"))
        XCTAssertEqual(page.absoluteString, "jetbrains://idea/settings?name=Plugins")
    }
}
