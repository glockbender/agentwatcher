import AppKit
import XCTest

@testable import AgentWatchApp

/// The control a person presses a new combination into.
@MainActor
final class ShortcutRecorderTests: XCTestCase {
    /// AppKit hands a `⌘` combination to `performKeyEquivalent` and never to `keyDown`, so a
    /// recorder that only overrides `keyDown` cannot record the app's own default, `⌥⌘W`. This
    /// is the test that keeps that override in place.
    func testACommandCombinationArrivesByTheOnlyRouteAppKitGivesIt() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        let claimed = recorder.performKeyEquivalent(
            with: try press(keyCode: 13, flags: [.option, .command])
        )

        XCTAssertTrue(claimed, "an unclaimed key equivalent goes on to somebody else's menu")
        XCTAssertEqual(recorded, .recorded(try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))))
    }

    func testACombinationWithoutCommandArrivesAsAnOrdinaryKeyPress() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))

        XCTAssertEqual(recorded, .recorded(try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: [.control, .shift]))))
    }

    /// AppKit puts `.function` in the modifier set of every F-key press. The recorder has to
    /// drop it rather than treat it as something held down — otherwise `F13` would arrive as a
    /// combination with one modifier and record as a different shortcut than the one pressed.
    func testAFunctionKeyRecordsOnItsOwn() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        recorder.keyDown(with: try press(keyCode: 105, flags: [.function]))

        XCTAssertEqual(recorded, .recorded(try XCTUnwrap(WidgetShortcut(keyCode: 105, modifiers: []))))
    }

    func testEscapeLeavesTheCombinationAsItWas() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        recorder.keyDown(with: try press(keyCode: 53, flags: []))

        XCTAssertEqual(recorded, .cancelled)
        XCTAssertFalse(recorder.isRecording)
    }

    func testDeleteTakesTheCombinationAway() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        recorder.keyDown(with: try press(keyCode: 51, flags: []))

        XCTAssertEqual(recorded, .cleared)
    }

    /// Refused, not ignored: a press that does nothing and says nothing reads as a broken
    /// control. The window turns this into the sentence that says what would be accepted.
    func testAPressThatCannotBecomeAShortcutIsRefusedOutLoud() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()

        recorder.keyDown(with: try press(keyCode: 13, flags: []))

        XCTAssertEqual(recorded, .refused)
        XCTAssertTrue(recorder.isRecording, "still waiting for one it can take")
    }

    /// Clicking elsewhere is a change of mind, and it is the one the recorder would otherwise
    /// never hear about: every other way out of recording is a key press, and this one is the
    /// absence of any. Left recording, the button sits reading "Press a combination…" and the
    /// combination it was called to replace stays muted — registered, printed beside the menu
    /// line, and doing nothing.
    func testGivingUpTheFocusEndsTheRecording() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let recorder = ShortcutRecorderButton()
        try XCTUnwrap(window.contentView).addSubview(recorder)
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }
        recorder.startRecording()
        XCTAssertTrue(recorder.isRecording, "nothing to give up otherwise")

        window.makeFirstResponder(nil)

        XCTAssertEqual(recorded, .cancelled)
        XCTAssertFalse(recorder.isRecording)
    }

    func testAKeyPressedWhileNotRecordingIsNoneOfItsBusiness() throws {
        let recorder = ShortcutRecorderButton()
        var recorded: ShortcutRecording?
        recorder.onRecording = { recorded = $0 }

        let claimed = recorder.performKeyEquivalent(
            with: try press(keyCode: 13, flags: [.option, .command])
        )

        XCTAssertFalse(claimed)
        XCTAssertNil(recorded)
    }

    private func press(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
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
}
