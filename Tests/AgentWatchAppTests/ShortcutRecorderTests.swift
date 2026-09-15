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
        let (recorder, recorded) = waitingRecorder()

        let claimed = recorder.performKeyEquivalent(
            with: try press(keyCode: 13, flags: [.option, .command])
        )

        XCTAssertTrue(claimed, "an unclaimed key equivalent goes on to somebody else's menu")
        XCTAssertEqual(recorded.last, .recorded(try optionCommandW()))
    }

    func testACombinationWithoutCommandArrivesAsAnOrdinaryKeyPress() throws {
        let (recorder, recorded) = waitingRecorder()

        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))

        XCTAssertEqual(
            recorded.last,
            .recorded(try XCTUnwrap(WidgetShortcut(keyCode: 96, modifiers: [.control, .shift])))
        )
    }

    /// AppKit puts `.function` in the modifier set of every F-key press. The recorder has to
    /// drop it rather than treat it as something held down — otherwise `F13` would arrive as a
    /// combination with one modifier and record as a different shortcut than the one pressed.
    func testAFunctionKeyRecordsOnItsOwn() throws {
        let (recorder, recorded) = waitingRecorder()

        recorder.keyDown(with: try press(keyCode: 105, flags: [.function]))

        XCTAssertEqual(recorded.last, .recorded(try XCTUnwrap(WidgetShortcut(keyCode: 105, modifiers: []))))
    }

    func testEscapeLeavesTheCombinationAsItWas() throws {
        let (recorder, recorded) = waitingRecorder()

        recorder.keyDown(with: try press(keyCode: 53))

        XCTAssertEqual(recorded.last, .cancelled)
        XCTAssertFalse(recorder.isRecording)
    }

    func testDeleteTakesTheCombinationAway() throws {
        let (recorder, recorded) = waitingRecorder()

        recorder.keyDown(with: try press(keyCode: 51))

        XCTAssertEqual(recorded.last, .cleared)
    }

    /// Refused, not ignored: a press that does nothing and says nothing reads as a broken
    /// control. The window turns this into the sentence that says what would be accepted.
    func testAPressThatCannotBecomeAShortcutIsRefusedOutLoud() throws {
        let (recorder, recorded) = waitingRecorder()

        recorder.keyDown(with: try press(keyCode: 13))

        XCTAssertEqual(recorded.last, .refused)
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
        let (recorder, recorded) = waitingRecorder()
        try XCTUnwrap(window.contentView).addSubview(recorder)
        recorder.startRecording()
        XCTAssertTrue(recorder.isRecording, "nothing to give up otherwise")

        window.makeFirstResponder(nil)

        XCTAssertEqual(recorded.last, .cancelled)
        XCTAssertFalse(recorder.isRecording)
    }

    func testAKeyPressedWhileNotRecordingIsNoneOfItsBusiness() throws {
        let recorder = ShortcutRecorderButton()
        let recorded = LastRecording()
        recorder.onRecording = { recorded.last = $0 }

        let claimed = recorder.performKeyEquivalent(
            with: try press(keyCode: 13, flags: [.option, .command])
        )

        XCTAssertFalse(claimed)
        XCTAssertNil(recorded.last)
    }

    /// A recorder already waiting for a press, and somewhere to keep what it reports.
    ///
    /// Three lines that every test here needs before it can say anything, and that no test here
    /// is about. The one test that must *not* be recording builds its own.
    private func waitingRecorder() -> (ShortcutRecorderButton, LastRecording) {
        let recorder = ShortcutRecorderButton()
        let recorded = LastRecording()
        recorder.onRecording = { recorded.last = $0 }
        recorder.startRecording()
        return (recorder, recorded)
    }
}

/// What the recorder last reported. A reference, because the recorder reports through a closure
/// and a local `var` cannot be read back from inside one.
@MainActor
private final class LastRecording {
    var last: ShortcutRecording?
}
