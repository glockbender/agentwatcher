import Foundation

/// What the shortcut section of the settings window says.
///
/// It carries more weight than the other sections' labels, because the menu beside it stays
/// silent when the combination does not work — a menu line that printed a dead `⌥⌘W` would be
/// the app promising what it cannot do. So every reason a shortcut is not working is said here,
/// in one sentence, visible without hovering over anything.

let shortcutSectionTitle = "Shortcut"
let shortcutClearTitle = "Clear"
let shortcutEmptyButton = "Click to record"
let shortcutRecordingButton = "Press a combination…"

/// What a shortcut may be made of, said in full.
///
/// Shown twice: as the recorder's tooltip before anything is pressed, and in place of the status
/// line after a press this app will not take. One sentence in both places, because a person who
/// reads it after a refusal is asking the same question as one who reads it before.
///
/// Punctuation is named as missing rather than merely left off the list. Somebody reaching for
/// `⌥⌘,` — the combination every Mac uses for settings — would otherwise be refused with no way
/// to tell whether the modifiers or the key were the problem, and would try again with the same
/// key and different modifiers.
let shortcutAcceptedKeys =
    "Hold ⌃, ⌥, ⇧ or ⌘ and press a letter, a digit, a function key or an arrow. "
    + "Punctuation is not offered: it moves between keyboard layouts."

@MainActor
func shortcutStatusLine(_ status: WidgetShortcutController.Status) -> String {
    switch status {
    case .none:
        "No shortcut. The widget is shown and hidden from the menu bar."
    case let .active(shortcut):
        "\(shortcut.displayed) shows and hides the widget from any application."
    case let .alreadyOurs(shortcut):
        "Agent Watch is still holding \(shortcut.displayed) from before and could not take it "
            + "again. Restarting the app clears it."
    case let .refused(shortcut, code):
        "macOS would not take \(shortcut.displayed) (error \(code)). Record a different one."
    }
}

/// Every sentence the status line can be asked to show, at its longest.
///
/// The window measures itself once, when it is built, so the room it leaves the status line has
/// to be the room the worst case needs. Without this the line was one line tall — and four of
/// the five sentences are two or more, so clearing the shortcut printed a sentence with its tail
/// cut off and nothing anywhere said so.
///
/// The combination used is the widest one there is: four modifiers and a three-character key.
@MainActor
func shortcutEveryStatusLine() -> [String] {
    guard
        let widest = WidgetShortcut(
            keyCode: 109,
            modifiers: [.control, .option, .shift, .command]
        )
    else {
        // Not a fallback that gets the answer wrong: this sentence is twice the length of any
        // other, so the room measured from it alone is still room enough for all of them.
        return [shortcutAcceptedKeys]
    }
    return [
        shortcutAcceptedKeys,
        shortcutStatusLine(.none),
        shortcutStatusLine(.active(widest)),
        shortcutStatusLine(.alreadyOurs(widest)),
        shortcutStatusLine(.refused(widest, code: -9878)),
    ]
}
