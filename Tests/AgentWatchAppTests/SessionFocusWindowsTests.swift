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

    /// A desktop client's own link shows its main window with the session in it: Claude.app's
    /// handler calls `show()` and `focus()`, ChatGPT.app's makes its primary window visible —
    /// read in their `app.asar` (Claude.app 2.26454.0, ChatGPT.app 26.1002.52244). Every other
    /// window of the client coming forward too would bury it, as with Ghostty.
    func testADesktopClientsSessionBringsOnlyTheWindowItShowsItIn() throws {
        for address in [
            "claude://code/continue?session=local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8",
            "codex://threads/019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b",
        ] {
            let link = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(SessionHostRegistry.activationOptions(for: .desktopClient(link)), [], address)
        }
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
