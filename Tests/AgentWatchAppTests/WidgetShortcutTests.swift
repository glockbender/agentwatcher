import AppKit
import XCTest

@testable import AgentWatchApp

final class WidgetShortcutTests: XCTestCase {
    func testAShortcutSurvivesItsStoredForm() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertEqual(WidgetShortcut(stored: shortcut.stored), shortcut)
    }

    /// A bare letter would be taken from every application on the machine, this one included —
    /// typing `w` anywhere would hide the widget instead of writing a `w`.
    func testAKeyWithNoModifierIsRefused() {
        XCTAssertNil(WidgetShortcut(keyCode: 13, modifiers: []))
    }

    func testAShortcutIsWrittenTheWayMacOSPrintsIt() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertEqual(shortcut.displayed, "⌥⌘W")
    }

    /// The order is the system's, not the order the keys were pressed in, so that the row in
    /// the settings window and the line in the menu read like every other shortcut on the Mac.
    func testEveryModifierIsPrintedInTheSystemOrder() throws {
        let shortcut = try XCTUnwrap(
            WidgetShortcut(keyCode: 49, modifiers: [.command, .shift, .option, .control])
        )

        XCTAssertEqual(shortcut.displayed, "⌃⌥⇧⌘Space")
    }

    /// A key this app cannot name is a key it cannot show — not in the settings row, not beside
    /// the menu line. Refusing it at the door is what keeps `displayed` from having a branch
    /// that prints nothing.
    func testAKeyWithNoNameIsRefused() {
        XCTAssertNil(WidgetShortcut(keyCode: 250, modifiers: [.command]))
    }

    /// `NSMenuItem` wants the character and the modifiers apart, and the character in lower
    /// case — an upper-case one silently adds `⇧` to what the menu prints.
    func testTheMenuIsGivenALowerCaseCharacterAndAMaskApart() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertEqual(shortcut.menuKeyEquivalent, "w")
        XCTAssertEqual(shortcut.menuModifierMask, [.option, .command])
    }

    func testAFunctionKeyReachesTheMenuAsItsOwnCharacter() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: [.control]))

        XCTAssertEqual(shortcut.displayed, "⌃F5")
        XCTAssertEqual(shortcut.menuKeyEquivalent, String(format: "%C", NSF5FunctionKey))
    }

    /// Caps Lock and the `fn` key arrive in the same set as `⌘`, and neither is something a
    /// person can be asked to hold down. Recording them would make the shortcut unrepeatable.
    func testARecordedPressKeepsOnlyTheModifiersAShortcutMayUse() throws {
        let press = try XCTUnwrap(
            keyPress(keyCode: 13, flags: [.command, .option, .capsLock, .function])
        )

        XCTAssertEqual(
            WidgetShortcut(press: press),
            WidgetShortcut(keyCode: 13, modifiers: [.option, .command])
        )
    }

    func testAPressWithNothingHeldDownRecordsNothing() throws {
        let press = try XCTUnwrap(keyPress(keyCode: 13, flags: []))

        XCTAssertNil(WidgetShortcut(press: press))
    }

    private func keyPress(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
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
    }
}
