import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// How many of the host's windows a click brings forward.
///
/// Reported from a Ghostty with several windows open: the click landed on the right window
/// and the right tab, and every other Ghostty window came forward with it. The raise ran
/// first and took all of them, and the route then put the right one on top of the pile.
@MainActor
final class SessionFocusWindowsTests: XCTestCase {
    /// Ghostty's `focus` raises the terminal's own window — read in Ghostty 1.3.1's
    /// `BaseTerminalController.focusSurface`, which does `makeKeyAndOrderFront` on it — so
    /// there is nothing left for a wide net to do but undo that.
    func testAnAddressedGhosttyTabBringsOnlyItsOwnWindow() {
        XCTAssertEqual(
            SessionHostRegistry.activationOptions(for: .ghostty(terminalID: UUID().uuidString)),
            []
        )
    }

    /// The IDE plugin picks the window itself, with `ProjectUtil.focusProjectWindow`. Same
    /// bug, and only visible with more than one project window open — which is why it was
    /// reported from Ghostty first.
    func testAnAddressedIDETabBringsOnlyItsOwnWindow() throws {
        let address = try XCTUnwrap(URL(string: "jetbrains://goland/agent-watch/focus?pid=4242"))

        XCTAssertEqual(SessionHostRegistry.activationOptions(for: .jetBrains(address)), [])
    }

    /// With no route, the wide net is the whole point: the session is in one of those windows
    /// and Agent Watch cannot say which. A host with no dictionary and no plugin — and a
    /// Ghostty that would not name a single tab for this session — keeps today's behaviour.
    func testWithNoRouteToTheTabEveryWindowStillComesForward() {
        for route in [
            SessionHostRegistry.TabRoute.noTab(.unaddressable),
            .noTab(.missing("Ghostty did not answer; check Automation permission")),
            .noTab(.missing("several terminal tabs match this session's name")),
        ] {
            XCTAssertEqual(
                SessionHostRegistry.activationOptions(for: route),
                [.activateAllWindows],
                "nothing will pick a window, so all of them is the widest net there is"
            )
        }
    }
}
