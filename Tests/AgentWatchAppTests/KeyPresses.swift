import AppKit
import XCTest

@testable import AgentWatchApp

extension XCTestCase {
    /// One key press, as AppKit would hand it to a view.
    ///
    /// The characters are deliberately empty: nothing in the shortcut reads them. A key code
    /// names a place on the keyboard and the layout decides what is printed there, which is
    /// the whole reason `WidgetShortcut` stores the code — so a fixture that filled in a
    /// letter would be stating something the code under test must never depend on.
    ///
    /// Shared because three files were each carrying their own copy of this call, and an
    /// eleven-argument constructor copied three times is three places for one of them to
    /// quietly differ.
    func press(keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    /// The combination a fresh install is given, which is what most of these tests are about.
    func optionCommandW() throws -> WidgetShortcut {
        try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))
    }
}
