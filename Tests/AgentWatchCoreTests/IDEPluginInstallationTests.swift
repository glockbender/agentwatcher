import Foundation
import Testing

@testable import AgentWatchCore

/// What the installation section of the tooling window is allowed to claim about an IDE.
struct IDEPluginInstallationTests {
    /// The sample is a real reply, copied from this machine.
    @Test func aReplyIsReadWithEverythingThePluginPutInIt() throws {
        let data = Data(
            """
            {"token":"nsw4k0bfzomrpl7o","pluginVersion":"0.1.2","ideBuild":"GO-261.26222.72",\
            "answeredAt":"2026-09-11T01:25:45.031277Z"}
            """.utf8
        )

        let reply = try #require(IDEPluginReply.parse(data))

        #expect(reply.token == "nsw4k0bfzomrpl7o")
        #expect(reply.pluginVersion == "0.1.2")
        #expect(reply.ideBuild == "GO-261.26222.72")
        #expect(reply.answeredAt != nil)
    }

    /// Java writes the fractional part only when it is not zero, so both shapes arrive from
    /// the same line of Kotlin — and one `ISO8601DateFormatter` reads only one of them.
    @Test func anInstantWithoutFractionalSecondsIsStillADate() throws {
        let data = Data(#"{"token":"aaaabbbbcccc","answeredAt":"2026-09-11T01:25:45Z"}"#.utf8)

        let reply = try #require(IDEPluginReply.parse(data))

        #expect(reply.answeredAt != nil)
        #expect(reply.pluginVersion == nil, "a field the plugin did not write is absent, not empty")
    }

    /// The token is the whole point of the file. Without one there is nothing to compare, so
    /// there is no answer here — only bytes.
    @Test func aFileWithoutATokenIsNotAnAnswer() {
        #expect(IDEPluginReply.parse(Data(#"{"pluginVersion":"0.1.3"}"#.utf8)) == nil)
        #expect(IDEPluginReply.parse(Data("not json at all".utf8)) == nil)
    }

    /// An IDE nothing can address cannot be asked, so "the plugin has never answered" would
    /// be a claim about a question that was never put.
    @Test func anIDEThatCannotBeAddressedIsSaidToBeThatRatherThanEmpty() {
        #expect(
            IDEPluginInstallation.presence(
                productScheme: nil,
                isDaemonInstalled: true,
                reply: nil,
                check: .notAsked
            ) == .unaddressable(.bundleNamesNoScheme)
        )
        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: false,
                reply: nil,
                check: .notAsked
            ) == .unaddressable(.daemonMissing)
        )
    }

    /// The reply file outlives the plugin — nothing deletes it when the plugin is removed —
    /// so an old reply says "was loaded here", and only a fresh token says anything about now.
    @Test func anOldReplyIsNeverReadAsAnAnswerToThisQuestion() {
        let reply = IDEPluginReply(token: "abcdefgh1234", pluginVersion: "0.1.2", ideBuild: nil, answeredAt: nil)

        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .notAsked
            ) == .answeredEarlier(reply)
        )
        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .waiting(token: "somethingelse1")
            ) == .checking,
            "the address is out and the answer has not come — not yet an answer either way"
        )
        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .done(token: "abcdefgh1234")
            ) == .confirmed(reply)
        )
    }

    /// The state the whole check exists for: the file says the plugin was here, and it did
    /// not answer just now. A plugin that has been removed — or an IDE updated into a new
    /// settings directory — looks exactly like a working one until somebody asks.
    @Test func silenceAfterAskingOutweighsAFileFromBefore() {
        let reply = IDEPluginReply(token: "abcdefgh1234", pluginVersion: "0.1.2", ideBuild: nil, answeredAt: nil)

        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: reply,
                check: .done(token: "zzzzzzzz9999")
            ) == .askedAndSilent(reply)
        )
    }

    @Test func anIDEThatHasNeverAnsweredIsSaidSoOnce() {
        #expect(
            IDEPluginInstallation.presence(
                productScheme: "goland",
                isDaemonInstalled: true,
                reply: nil,
                check: .notAsked
            ) == .neverAnswered
        )
    }

    /// The directory may hold a release beside the one before it, and the name is where the
    /// version is — which is what lets a row say the IDE answered an older one.
    @Test func theHighestVersionInTheDirectoryIsTheOneOffered() {
        let staged = IDEPluginInstallation.stagedPlugin(
            among: [
                "agent-watch-ide-0.1.9.zip",
                "agent-watch-ide-0.1.10.zip",
                "agent-watch-ide-0.1.3.zip",
                ".DS_Store",
                "something-else-2.0.zip",
            ]
        )

        #expect(staged == StagedIDEPlugin(fileName: "agent-watch-ide-0.1.10.zip", version: "0.1.10"))
    }

    @Test func anEmptyDirectoryOffersNothing() {
        #expect(IDEPluginInstallation.stagedPlugin(among: []) == nil)
        #expect(IDEPluginInstallation.stagedPlugin(among: ["agent-watch-ide-.zip"]) == nil)
    }

    /// `0.1.10` is later than `0.1.9`, and no comparison of strings will say so.
    @Test func versionsCompareByNumberWhereTheyAreNumbers() {
        #expect(IDEPluginInstallation.isVersion("0.1.10", newerThan: "0.1.9"))
        #expect(!IDEPluginInstallation.isVersion("0.1.9", newerThan: "0.1.10"))
        #expect(!IDEPluginInstallation.isVersion("0.1.3", newerThan: "0.1.3"))
        #expect(IDEPluginInstallation.isVersion("1.0", newerThan: "0.9.9"))
    }

    /// The plugin refuses anything that is not letters and digits, because any page in a
    /// browser can open a `jetbrains://` link. This is that rule, on this side.
    @Test func everyTokenThisAppMakesIsOneThePluginWillAccept() {
        for _ in 0..<50 {
            #expect(IDEPluginInstallation.isAcceptableToken(IDEPluginInstallation.newToken()))
        }
        #expect(!IDEPluginInstallation.isAcceptableToken("short"))
        #expect(!IDEPluginInstallation.isAcceptableToken("has a space in it"))
        #expect(!IDEPluginInstallation.isAcceptableToken(String(repeating: "a", count: 65)))
    }

    /// The scheme comes out of somebody else's application bundle and is pasted into a URL.
    @Test func onlyARealSchemeAndARealTokenBecomeAnAddress() throws {
        let ping = try #require(IDEPluginInstallation.pingURL(productScheme: "goland", token: "abcdefgh1234"))
        #expect(ping.absoluteString == "jetbrains://goland/agent-watch/ping?token=abcdefgh1234")

        #expect(IDEPluginInstallation.pingURL(productScheme: "go/land", token: "abcdefgh1234") == nil)
        #expect(IDEPluginInstallation.pingURL(productScheme: "goland", token: "no") == nil)

        let page = try #require(IDEPluginInstallation.pluginsPageURL(productScheme: "idea"))
        #expect(page.absoluteString == "jetbrains://idea/settings?name=Plugins")
    }
}
