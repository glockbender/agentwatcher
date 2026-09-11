import Foundation
import Testing

@testable import AgentWatchCore

/// The four preconditions for asking an IDE to select a tab, and the address itself.
struct JetBrainsFocusTests {
    @Test func aJetBrainsIDEWithEverythingInPlaceIsAsked() {
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: "GoLand2026.1",
            productScheme: "goland",
            isDaemonInstalled: true,
            hasAnsweredPing: true,
            agentProcessID: 37664
        )

        #expect(decision == .ask(URL(string: "jetbrains://goland/agent-watch/focus?pid=37664")!))
    }

    /// Every other host answers this way, and it is not a fault: a terminal has no plugin
    /// and never will.
    @Test func anythingThatIsNotAJetBrainsIDEDeclinesFirst() {
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: nil,
            productScheme: "ghostty",
            isDaemonInstalled: true,
            hasAnsweredPing: true,
            agentProcessID: 1
        )

        #expect(decision == .decline(.notAJetBrainsIDE))
    }

    /// The three fixable reasons, each reported as itself so the installation screen can say
    /// which one it is.
    @Test func eachMissingPieceIsNamed() {
        #expect(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: nil,
                isDaemonInstalled: true,
                hasAnsweredPing: true,
                agentProcessID: 1
            ) == .decline(.bundleNamesNoScheme)
        )
        #expect(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: "goland",
                isDaemonInstalled: false,
                hasAnsweredPing: true,
                agentProcessID: 1
            ) == .decline(.daemonMissing)
        )
        #expect(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: "goland",
                isDaemonInstalled: true,
                hasAnsweredPing: false,
                agentProcessID: 1
            ) == .decline(.pluginNeverAnswered)
        )
    }

    /// The scheme comes out of somebody else's application bundle and goes straight into a
    /// URL. A `/` in it would not be a scheme but a second path segment, and the command the
    /// IDE ran would not be the one written here.
    @Test func aSchemeThatIsNotASchemeIsRefused() {
        for scheme in ["go land", "go/land", "1goland", "", "goland?x", "go#land"] {
            #expect(JetBrainsFocus.focusURL(productScheme: scheme, agentProcessID: 1) == nil)
        }
        #expect(JetBrainsFocus.focusURL(productScheme: "intellij-idea.ce", agentProcessID: 1) != nil)
    }

    /// The copy the IDE installs for itself, so it is there for somebody who never installed
    /// Toolbox.
    @Test func theDaemonIsLookedForWhereTheIDEPutsIt() {
        let bundle = JetBrainsFocus.daemonBundle(userHome: URL(fileURLWithPath: "/Users/x"))

        #expect(
            bundle.path
                == "/Users/x/Library/Application Support/JetBrains/Daemon/bundles/current/jetbrainsd.app"
        )
    }
}
