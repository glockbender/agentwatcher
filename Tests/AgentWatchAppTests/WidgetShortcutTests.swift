import AppKit
import XCTest

@testable import AgentWatchApp

final class WidgetShortcutTests: XCTestCase {
    func testAShortcutSurvivesItsStoredForm() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertEqual(WidgetShortcut(stored: shortcut.stored), shortcut)
    }

    /// A key with nothing held down has no separator in its stored form at all — `96`, not
    /// `+96`. The parser reads the last part as the code and the rest as modifiers, so a lone
    /// part has to come back as a shortcut with no modifiers rather than as nothing.
    func testAKeyWithNothingHeldDownSurvivesItsStoredForm() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: []))

        XCTAssertEqual(shortcut.stored, "96")
        XCTAssertEqual(WidgetShortcut(stored: "96"), shortcut)
    }

    /// A bare letter would be taken from every application on the machine, this one included —
    /// typing `w` anywhere would hide the widget instead of writing a `w`.
    func testAKeyWithNoModifierIsRefused() {
        XCTAssertNil(WidgetShortcut(keyCode: 13, modifiers: []))
    }

    /// The one key that may stand alone. Nobody types `F13` into a document, and `F13`–`F19` are
    /// there on a full keyboard with nothing else asking for them — which is exactly why people
    /// reach for them as shortcuts.
    func testAFunctionKeyIsAllowedWithNothingHeldDown() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: []))

        XCTAssertEqual(shortcut.displayed, "F5")
    }

    /// The exception stops at the function keys. An arrow reaches the app through the same kind
    /// of code point, and letting one stand alone would take every arrow press on the machine —
    /// including the ones moving a cursor through this very sentence.
    func testAnArrowStillNeedsSomethingHeldDown() {
        XCTAssertNil(WidgetShortcut(keyCode: 123, modifiers: []))
    }

    func testTheFunctionKeysReachF19() throws {
        let thirteen = try XCTUnwrap(WidgetShortcut(keyCode: 105, modifiers: []))
        let nineteen = try XCTUnwrap(WidgetShortcut(keyCode: 80, modifiers: []))

        XCTAssertEqual(thirteen.displayed, "F13")
        XCTAssertEqual(nineteen.displayed, "F19")
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

    /// The code point, not the formula that builds it. Asserting against
    /// `String(format: "%C", NSF5FunctionKey)` — which is what the source does — would pass just
    /// as well if that formula started producing nothing at all, and an empty key equivalent is
    /// a menu line with no shortcut printed on it.
    func testAFunctionKeyReachesTheMenuAsItsOwnCharacter() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: [.control]))

        XCTAssertEqual(shortcut.displayed, "⌃F5")
        XCTAssertEqual(shortcut.menuKeyEquivalent.unicodeScalars.map(\.value), [0xF708])
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
