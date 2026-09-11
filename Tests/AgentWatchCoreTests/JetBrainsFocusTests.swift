import Foundation
import XCTest

@testable import AgentWatchCore

/// The four preconditions for asking an IDE to select a tab, and the address itself.
final class JetBrainsFocusTests: XCTestCase {
    func testAJetBrainsIDEWithEverythingInPlaceIsAsked() {
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: "GoLand2026.1",
            productScheme: "goland",
            isDaemonInstalled: true,
            hasAnsweredPing: true,
            agentProcessID: 37664
        )

        XCTAssertEqual(decision, .ask(URL(string: "jetbrains://goland/agent-watch/focus?pid=37664")!))
    }

    /// Every other host answers this way, and it is not a fault: a terminal has no plugin
    /// and never will.
    func testAnythingThatIsNotAJetBrainsIDEDeclinesFirst() {
        let decision = JetBrainsFocus.decision(
            dataDirectoryName: nil,
            productScheme: "ghostty",
            isDaemonInstalled: true,
            hasAnsweredPing: true,
            agentProcessID: 1
        )

        XCTAssertEqual(decision, .decline(.notAJetBrainsIDE))
    }

    /// The three fixable reasons, each reported as itself so the installation screen can say
    /// which one it is.
    func testEachMissingPieceIsNamed() {
        XCTAssertEqual(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: nil,
                isDaemonInstalled: true,
                hasAnsweredPing: true,
                agentProcessID: 1
            ),
            .decline(.bundleNamesNoScheme)
        )
        XCTAssertEqual(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: "goland",
                isDaemonInstalled: false,
                hasAnsweredPing: true,
                agentProcessID: 1
            ),
            .decline(.daemonMissing)
        )
        XCTAssertEqual(
            JetBrainsFocus.decision(
                dataDirectoryName: "GoLand2026.1",
                productScheme: "goland",
                isDaemonInstalled: true,
                hasAnsweredPing: false,
                agentProcessID: 1
            ),
            .decline(.pluginNeverAnswered)
        )
    }

    /// The scheme comes out of somebody else's application bundle and goes straight into a
    /// URL. A `/` in it would not be a scheme but a second path segment, and the command the
    /// IDE ran would not be the one written here.
    func testASchemeThatIsNotASchemeIsRefused() {
        for scheme in ["go land", "go/land", "1goland", "", "goland?x", "go#land"] {
            XCTAssertNil(JetBrainsFocus.focusURL(productScheme: scheme, agentProcessID: 1), scheme)
        }
        XCTAssertNotNil(JetBrainsFocus.focusURL(productScheme: "intellij-idea.ce", agentProcessID: 1))
    }

    /// The copy the IDE installs for itself, so it is there for somebody who never installed
    /// Toolbox.
    func testTheDaemonIsLookedForWhereTheIDEPutsIt() {
        let bundle = JetBrainsFocus.daemonBundle(userHome: URL(fileURLWithPath: "/Users/x"))

        XCTAssertEqual(
            bundle.path,
            "/Users/x/Library/Application Support/JetBrains/Daemon/bundles/current/jetbrainsd.app"
        )
    }
}
