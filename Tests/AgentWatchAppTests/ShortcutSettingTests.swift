import AgentWatchCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

/// The shortcut on the General page, driven through the page itself: the recorder the page
/// builds, wired to the model the way SwiftUI wires it. The window is never shown, so nothing
/// takes the focus from whoever is working.
@MainActor
final class ShortcutSettingTests: XCTestCase {
    func testThePageShowsTheCombinationTheWidgetAnswersTo() throws {
        let (window, _, _) = try makeWindow()

        XCTAssertEqual(try recorder(in: window).title, "⌥⌘W")
    }

    func testACombinationRecordedOnThePageIsKept() throws {
        let (window, settings, _) = try makeWindow()
        let recorder = try recorder(in: window)

        recorder.sendAction(recorder.action, to: recorder.target)
        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))
        settle()

        XCTAssertEqual(settings.toggleShortcut?.displayed, "⌃⇧F5")
        XCTAssertEqual(recorder.title, "⌃⇧F5")
    }

    func testClearingLeavesTheWidgetWithNoCombinationAtAll() throws {
        let (window, settings, _) = try makeWindow()

        window.model.clearShortcut()
        settle()

        XCTAssertNil(settings.toggleShortcut)
        XCTAssertEqual(try recorder(in: window).title, shortcutEmptyButton)
    }

    /// The control that cannot do its job stays where it is and says why — hiding it would
    /// leave the person with a widget that ignores the combination they can still see set.
    func testARegistrationThatDidNotTakeIsExplainedRatherThanHidden() throws {
        let (window, _, _) = try makeWindow(answer: .alreadyOurs)

        XCTAssertEqual(window.model.shortcutStatus, shortcutStatusLine(.alreadyOurs(try optionCommandW())))
        XCTAssertTrue(try recorder(in: window).isEnabled, "the way out is to record another")
    }

    func testAPressThatCannotBeAShortcutSaysWhatWouldBeAccepted() throws {
        let (window, _, _) = try makeWindow()
        let recorder = try recorder(in: window)

        recorder.sendAction(recorder.action, to: recorder.target)
        recorder.keyDown(with: try press(keyCode: 13, flags: []))

        XCTAssertEqual(window.model.shortcutStatus, shortcutAcceptedKeys)
    }

    /// The old combination is still registered while a new one is being chosen. Left live, it
    /// would hide the widget out from under the person in the middle of choosing — and the
    /// press that did it would also be the press they were trying to record.
    func testTheOldCombinationGoesQuietWhileANewOneIsBeingChosen() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)

        recorder.sendAction(recorder.action, to: recorder.target)

        XCTAssertTrue(shortcuts.isMuted)
    }

    func testTheCombinationSpeaksAgainOnceTheChoosingIsOver() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)

        recorder.keyDown(with: try press(keyCode: 96, flags: [.control, .shift]))

        XCTAssertFalse(shortcuts.isMuted)
    }

    /// A press it will not take leaves the recorder waiting for another, so the quiet lasts
    /// exactly as long as that wait — not until the first press, whatever it was.
    func testTheCombinationStaysQuietWhileTheRecorderIsStillWaiting() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)

        recorder.keyDown(with: try press(keyCode: 13, flags: []))

        XCTAssertTrue(shortcuts.isMuted)
    }

    /// A person who starts recording and changes their mind presses nothing, so nothing
    /// reports anything; each way of walking away has to end the quiet by itself.
    func testWalkingAwayFromTheRecorderLetsTheCombinationSpeakAgain() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)
        XCTAssertTrue(shortcuts.isMuted)

        try XCTUnwrap(window.window).makeFirstResponder(nil)
        settle()

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertEqual(recorder.title, "⌥⌘W", "and the button stops asking for a press")
    }

    func testLeavingThePageMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)

        window.model.go(.rows)

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertFalse(recorder.isRecording)
    }

    /// Worth its own test because the way out is a different one: AppKit does not promise
    /// that closing a window takes the focus off the control inside it.
    func testClosingTheWindowMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)

        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertFalse(recorder.isRecording)
    }

    func testLeavingForAnotherApplicationMidRecordingLetsTheCombinationSpeakAgain() throws {
        let (window, _, shortcuts) = try makeWindow()
        let recorder = try recorder(in: window)
        recorder.sendAction(recorder.action, to: recorder.target)

        window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertFalse(shortcuts.isMuted)
        XCTAssertFalse(recorder.isRecording)
    }

    /// The settings window on its General page, built but not shown.
    private func makeWindow(
        answer: ShortcutRegistrationOutcome = .registered
    ) throws -> (SettingsWindowController, WidgetSettingsStore, WidgetShortcutController) {
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let shortcuts = FakeShortcutRegistrar.controller(for: settings, answer: answer)
        shortcuts.apply()
        let host = FakeAppHost()
        addTeardownBlock { _ = host }
        let window = SettingsWindowController(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences), shortcuts: shortcuts, host: host, version: nil)
        window.model.go(.general)
        window.buildPages()
        settle()
        return (window, settings, shortcuts)
    }

    private func recorder(in window: SettingsWindowController) throws -> ShortcutRecorderButton {
        func find(in view: NSView) -> ShortcutRecorderButton? {
            (view as? ShortcutRecorderButton) ?? view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.window?.contentView.flatMap(find), "the General page has no recorder")
    }

    /// SwiftUI builds and updates the page over a few turns of the run loop.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
}
