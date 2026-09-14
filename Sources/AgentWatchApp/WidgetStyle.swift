import AppKit

/// The measurements and type the widget is drawn with.
///
/// Gathered because they were being decided in five files at once: four different corner
/// radii, and `NSFont.systemFont(ofSize:)` spelled out by hand in as many places again. A
/// constant that lives beside the view that uses it is a constant nobody can change once.
@MainActor
enum WidgetStyle {
    /// The widget's own outline, and the highlight that traces it.
    static let windowCornerRadius: CGFloat = 10
    /// Anything that sits inside the widget: the hover card, a highlighted row.
    static let panelCornerRadius: CGFloat = 6
    static let rowCornerRadius: CGFloat = 4

    /// Where the widget's content starts, measured from its own edge. One number, because a
    /// row and the empty state have to line up and used to be given 10 and 14.
    static let contentInset: CGFloat = 10

    /// The small template symbol a row draws beside its identity: the mark that says the row
    /// may be out of date.
    ///
    /// Measured rather than asked of the image: a template symbol reports its own natural
    /// size, which is not the size it is drawn at here.
    ///
    /// It used to be shared with the symbol for where a session runs, which a row no longer
    /// draws. Its own number either way — borrowing one made a warning triangle change size
    /// whenever the other mark did.
    static let rowGlyph = NSSize(width: 13, height: 13)

    /// The session's own name — the one thing in a row that gives way under pressure.
    static let titleFont = NSFont.systemFont(ofSize: 12)
    /// Activity and context counters.
    static let countsFont = NSFont.systemFont(ofSize: 12)
    /// Account usage under the divider.
    static let usageFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The hover card.
    static let secondaryFont = NSFont.systemFont(ofSize: 11)
    /// The `▾ N more` badge. Smaller than anything else here: it lies over a row rather than
    /// beside one, so it has to read as a mark on the list instead of as another line of it.
    static let overflowFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    /// The empty state, which is read from further away than a row.
    static let emptyTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let emptySubtitleFont = NSFont.systemFont(ofSize: 12)
    /// The glyph on a row's action button.
    static let buttonFont = NSFont.systemFont(ofSize: 10)
    /// What the row's timer turns when the session has gone quiet, and when it has gone
    /// quiet for long enough to say so.
    ///
    /// Fixed values for the same measured reason the lamp's table gives (`LampScheme`): a
    /// system colour adapts to the machine's light or dark appearance, and this number is
    /// drawn on the widget's own background — one of ten fixed colours a person picks, half
    /// of them light — so the adaptation was tracking a surface the timer never touches.
    /// These are `systemYellow` and `systemOrange` as they resolve on a dark machine, which
    /// is what the timer already looked like there.
    static let timerQuiet = NSColor(sRGB: "#FFD60A")
    static let timerStale = NSColor(sRGB: "#FF9F0A")

    /// Fully monospaced, not merely monospaced-digit: the unit letter is part of the value,
    /// and `m` is wider than `d` in a proportional face. With every glyph the same width,
    /// three characters is one width rather than four near-misses.
    static let timerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

/// How wide a label holding this text will actually be.
///
/// Here rather than among the row's wording: it measures a view, and the budget it feeds is
/// the one the other constants in this file describe. It lived in `WidgetText` because that
/// is where it was first needed.
///
/// Measured through a real label rather than through `NSAttributedString.size()`, which
/// returns the width of the glyphs alone. A label is wider than its text — `NSTextField`
/// keeps a small inset around the cell — and budgeting by the glyph width alone left every
/// row a few points short of what it went on to lay out.
@MainActor
func labelWidth(of text: String, font: NSFont) -> CGFloat {
    guard !text.isEmpty else {
        return 0
    }
    let label = NSTextField(labelWithString: text)
    label.font = font
    return ceil(label.fittingSize.width)
}

extension NSView {
    /// Pins this view to all four edges of another, which the widget needed in six places.
    func pinToEdges(of other: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor),
            trailingAnchor.constraint(equalTo: other.trailingAnchor),
            topAnchor.constraint(equalTo: other.topAnchor),
            bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }

    /// Fixes this view at exactly this size, and makes it refuse to be stretched or squeezed.
    ///
    /// The size has to be imposed from outside for the pictures in a row: an application icon
    /// carries several representations and an image view sizes itself from the largest of
    /// them, whatever `NSImage.size` was set to — measured at 32 points, taller than the row. The
    /// row's `×` is here for the opposite reason: a button that sized itself to its own glyph
    /// would be a different width on every row it appears on.
    func pinSize(to size: NSSize) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
}
