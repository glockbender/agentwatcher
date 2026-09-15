import AppKit

/// What came of one key press into the recorder.
enum ShortcutRecording: Equatable {
    case recorded(WidgetShortcut)
    /// `⌫` — the widget keeps its menu line and loses its combination.
    case cleared
    /// `⎋` — whatever was there before stays.
    case cancelled
    /// A press this app will not take. Said out loud rather than ignored: a control that
    /// swallows a press and shows nothing reads as broken.
    case refused
}

/// A button that, once pressed, waits for a key combination and reports it.
///
/// A button rather than a drawn field because a button already looks and behaves like a
/// control that can be focused and clicked, and this one needs nothing else — the combination
/// is its title.
@MainActor
final class ShortcutRecorderButton: NSButton {
    /// Told once per key press while recording, whatever came of it.
    var onRecording: ((ShortcutRecording) -> Void)?

    private(set) var isRecording = false

    /// Key codes that mean something to the recorder itself and can never be a shortcut.
    private enum Control {
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// Losing the focus is a change of mind, and the only one that arrives without a key press.
    ///
    /// Every other way out of recording is a key: `⎋`, `⌫`, or a combination to keep. Clicking
    /// past the button is none of them, so without this the recorder stayed in the middle of a
    /// recording that nothing would ever finish — and the combination it was called to replace
    /// stayed muted while the menu went on printing it.
    override func resignFirstResponder() -> Bool {
        guard isRecording else {
            return super.resignFirstResponder()
        }
        stopRecording()
        onRecording?(.cancelled)
        return super.resignFirstResponder()
    }

    func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func stopRecording() {
        isRecording = false
        needsDisplay = true
    }

    /// The only route a `⌘` combination ever takes.
    ///
    /// AppKit resolves key equivalents before anybody's `keyDown`, so `⌥⌘W` — this app's own
    /// default — would never reach the recorder without this. Claiming the event matters as
    /// much as reading it: an unclaimed one goes on to be matched against every menu on screen.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        take(event)
        return true
    }

    /// The route everything without `⌘` takes, `⎋` and `⌫` included.
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        take(event)
    }

    private func take(_ event: NSEvent) {
        switch event.keyCode {
        case Control.escape:
            stopRecording()
            onRecording?(.cancelled)
        case Control.delete:
            stopRecording()
            onRecording?(.cleared)
        default:
            guard let shortcut = WidgetShortcut(press: event) else {
                // Still recording: the person pressed something, and the next press is far more
                // likely to be another try than a change of mind.
                onRecording?(.refused)
                return
            }
            stopRecording()
            onRecording?(.recorded(shortcut))
        }
    }
}
