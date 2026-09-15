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

/// Named keys rather than "a valid key", so that the person can act on it without guessing.
let shortcutRefusedPress =
    "Hold ⌃, ⌥, ⇧ or ⌘ and press a letter, a digit, a function key or an arrow."

@MainActor
func shortcutStatusLine(_ status: WidgetShortcutController.Status) -> String {
    switch status {
    case .none:
        "No shortcut. The widget is shown and hidden from the menu bar."
    case let .active(shortcut):
        "\(shortcut.displayed) shows and hides the widget from any application."
    case let .taken(shortcut):
        "\(shortcut.displayed) belongs to another application. Record a different one."
    case let .refused(shortcut, code):
        "macOS would not take \(shortcut.displayed) (error \(code)). Record a different one."
    }
}
