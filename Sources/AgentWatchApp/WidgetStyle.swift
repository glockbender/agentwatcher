import AppKit

/// The measurements and type the widget is drawn with, at the size a person chose.
///
/// Gathered because they were being decided in five files at once: four different corner
/// radii, and `NSFont.systemFont(ofSize:)` spelled out by hand in as many places again. A
/// constant that lives beside the view that uses it is a constant nobody can change once.
///
/// A value rather than a table of statics, and that is what the scale changed. Every number
/// below follows the scale, and a `static let` computed from one of them would be worked out
/// on first use and then never again — three already were, including the width the row
/// reserves for its timer. So the scale is carried, not stored: the widget's views are handed
/// a style the way they are handed a background, and a new scale is a new style, which is a
/// rebuild rather than a value that has to be found and refreshed everywhere it reached.
///
/// The row geometry lives here for the same reason, not because it is typography: it is what
/// the fonts and the icons force. A row 19 points tall is 19 points because of what stands in
/// it, and scaling one without the other gives a row whose contents no longer fit.
@MainActor
struct WidgetStyle {
    /// What everything here is multiplied by. 1 is the size every number below was tuned at.
    let scale: CGFloat

    /// The widget as it was before there was a scale, and as every window that is not the
    /// widget still draws: the settings window is an ordinary macOS window, and a person who
    /// enlarges the widget is not asking for larger controls in the window they did it from.
    static let standard = WidgetStyle(scale: 1)

    init(scale: CGFloat = 1) {
        self.scale = min(max(scale, WidgetSettingsStore.minimumScale), WidgetSettingsStore.maximumScale)
    }

    /// A tuned number at this scale, rounded to a whole point.
    ///
    /// Rounded because half a point is a blurred edge: at 125% a 19-point row is 23.75, and
    /// Auto Layout will place a label on that half point rather than snap it.
    func points(_ base: CGFloat) -> CGFloat {
        (base * scale).rounded()
    }

    private func size(_ base: CGFloat) -> NSSize {
        NSSize(width: points(base), height: points(base))
    }

    // MARK: - Chrome

    /// The widget's own outline, and the highlight that traces it.
    ///
    /// Unscaled, with the two radii below: a corner is the window's shape rather than
    /// something to read, and a widget whose corners grew with its text would stop looking
    /// like the same widget.
    static let windowCornerRadius: CGFloat = 10
    /// Anything that sits inside the widget: the hover card, a highlighted row.
    static let panelCornerRadius: CGFloat = 6
    static let rowCornerRadius: CGFloat = 4

    /// Where the widget's content starts, measured from its own edge. One number, because a
    /// row and the empty state have to line up and used to be given 10 and 14.
    var contentInset: CGFloat { points(10) }

    // MARK: - Type

    /// The session's own name — the one thing in a row that gives way under pressure.
    var titleFont: NSFont { .systemFont(ofSize: points(12)) }
    /// Activity and context counters.
    var countsFont: NSFont { .systemFont(ofSize: points(12)) }
    /// Account usage under the divider.
    var usageFont: NSFont { .systemFont(ofSize: points(11), weight: .medium) }
    /// The hover card.
    var secondaryFont: NSFont { .systemFont(ofSize: points(11)) }
    /// The `+N` badges. Smaller than anything else here: they lie over a row rather than
    /// beside one, so they have to read as a mark on the list instead of as another line of it.
    var overflowFont: NSFont { .systemFont(ofSize: points(9), weight: .medium) }
    /// The empty state, which is read from further away than a row.
    var emptyTitleFont: NSFont { .systemFont(ofSize: points(14), weight: .semibold) }
    var emptySubtitleFont: NSFont { .systemFont(ofSize: points(12)) }
    /// The glyph on a row's action button.
    var buttonFont: NSFont { .systemFont(ofSize: points(10)) }

    /// Fully monospaced, not merely monospaced-digit: the unit letter is part of the value,
    /// and `m` is wider than `d` in a proportional face. With every glyph the same width,
    /// three characters is one width rather than four near-misses.
    var timerFont: NSFont { .monospacedSystemFont(ofSize: points(11), weight: .regular) }

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

    // MARK: - Pictures

    /// The agent's own application icon, the one picture in a row that is not a symbol.
    var agentIconSize: NSSize { size(15) }

    /// A counter's symbol, and the point size it is drawn at.
    ///
    /// Both, because a symbol has two sizes: the box the image view is held to, and the
    /// weight the symbol itself is rendered at. Scaling only the box grows the space around a
    /// symbol that stays small inside it.
    var activityIconSize: NSSize { size(12) }
    var activityIconPointSize: CGFloat { points(11) }

    /// The small template symbol a row draws beside its identity: the mark that says the row
    /// may be out of date.
    ///
    /// Measured rather than asked of the image: a template symbol reports its own natural
    /// size, which is not the size it is drawn at here.
    ///
    /// It used to be shared with the symbol for where a session runs, which a row no longer
    /// draws. Its own number either way — borrowing one made a warning triangle change size
    /// whenever the other mark did.
    var rowGlyph: NSSize { size(13) }
    var rowGlyphPointSize: CGFloat { points(10) }

    /// The lamp, which is the widget's one piece of colour and the thing a row is scanned for.
    var lampDiameter: CGFloat { points(9) }

    // MARK: - A row

    /// The height of a row, which every row is held to whatever it holds. It used to follow
    /// from the buttons, the tallest thing in a row, until a row could have none; a row of
    /// icons and labels alone came out three points shorter than one with a dismiss button.
    /// The widget's self-sizing height reserves exactly this per row. It used to be called
    /// `approximate`, from when the sizing only estimated; a test now measures the two
    /// against each other, at every size on offer.
    ///
    /// The scaled 19 points, or the room the contents need — whichever is larger. The two
    /// part company only going down: a font half the size does not give a label half the
    /// height, because `NSTextField` keeps a minimum of its own around the text, so at half
    /// size a 6-point name still wants 9.5 points and the scaled row offered 10 including its
    /// insets. Measured rather than derived, for the same reason `timerWidth` is.
    var rowHeight: CGFloat {
        max(points(19), (tallestRowContent + 2 * rowVerticalInset).rounded(.up))
    }

    /// The gap above and below a row's contents, inside the hover wash. A point at every
    /// size: it is the hairline that keeps the wash off the text, and half a point of it
    /// would be nothing.
    let rowVerticalInset: CGFloat = 1

    /// The tallest thing a row can hold, which is a label or the agent's icon.
    ///
    /// The dismiss button is deliberately not in this list, and cannot be: its own size is
    /// capped by the row height, so asking it here would be circular. It never exceeds the
    /// row by construction.
    private var tallestRowContent: CGFloat {
        [
            labelHeight(font: titleFont),
            labelHeight(font: timerFont),
            agentIconSize.height,
            symbolHeight(pointSize: rowGlyphPointSize, boxed: rowGlyph),
            symbolHeight(pointSize: activityIconPointSize, boxed: activityIconSize),
        ].max() ?? 0
    }

    /// How tall a label at this font actually comes out, asked of a real one.
    private func labelHeight(font: NSFont) -> CGFloat {
        let label = NSTextField(labelWithString: "Ag")
        label.font = font
        return ceil(label.fittingSize.height)
    }

    /// How tall one of a row's small symbols actually comes out.
    ///
    /// Asked rather than taken from the box it is given, because a symbol image view has a
    /// floor of its own and will not go below it: told to be 7 points at half size, the
    /// warning triangle laid out at 9.5 — with three required height constraints of 7, 3.5
    /// and 6 on it at once, which is AppKit's own doing. A smaller `symbolConfiguration`,
    /// `imageScaling` set to scale down and an explicit `NSImage.size` were each tried and
    /// measured, and none moved it.
    ///
    /// So the row makes room for the symbol instead of pretending it shrank — the same answer
    /// the dismiss button's bezel gets at the other end of the range, and for the same reason:
    /// AppKit draws some things at a size of its choosing, and a row that ignores that clips
    /// them. At the tuned size and above, the scaled 19 points are larger than this anyway and
    /// nothing changes.
    private func symbolHeight(pointSize: CGFloat, boxed box: NSSize) -> CGFloat {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        view.image?.isTemplate = true
        view.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
        view.imageScaling = .scaleProportionallyDown
        view.pinSize(to: box)
        return ceil(view.fittingSize.height)
    }

    /// The gap between the things in a row.
    var elementSpacing: CGFloat { points(4) }

    /// The dismiss button, exactly this size. Never taller than the row, so a row with one is
    /// no taller than a row without.
    ///
    /// Capped by what the bezel can actually draw, and that cap is measured rather than
    /// chosen. AppKit refuses to draw a `.texturedRounded` bezel taller than its control size
    /// — it centres the bezel in the box it is given and stretches it sideways instead — so a
    /// box sized from the row grew in one direction only: at twice the size, 44 by 38 gave a
    /// wide, thin capsule with a small `×` adrift inside it. Drawn and looked at, which is the
    /// only way that shows.
    ///
    /// Measured, so the numbers are worth stating: the bezel's own height is 19, 23, 23, 23,
    /// 23 across the five sizes — it stops growing after 125% and the button then sits centred
    /// in a taller row — while its width goes on growing, 21, 25, 26, 27, 29.
    ///
    /// At the tuned size the height is untouched — the bezel's own 19 points are where the
    /// row's height came from in the first place — and the width gives up one point, 22 to 21,
    /// which is the button asking for exactly as much room as it draws in.
    var buttonSize: NSSize {
        guard buttonHasBezel else {
            // Nothing to stretch or squeeze: a borderless button is its glyph, and the box
            // around it is only the target. So the row decides it, as it did before there
            // was a bezel to respect.
            return NSSize(width: points(22), height: rowHeight)
        }
        let natural = Self.borderedButtonSize(font: buttonFont, controlSize: buttonControlSize)
        return NSSize(width: min(points(22), natural.width), height: min(rowHeight, natural.height))
    }

    /// What a bezelled `×` comes out as when nothing is imposed on it.
    private static func borderedButtonSize(font: NSFont, controlSize: NSControl.ControlSize) -> NSSize {
        RowDismissButton(font: font, controlSize: controlSize, perform: {}).fittingSize
    }

    /// Which of AppKit's four control sizes the row's `×` is drawn at.
    ///
    /// A bezel is not a number this file can scale. AppKit draws a button's bezel at the
    /// metrics of its control size and stretches it to whatever frame it is given, so a
    /// `.small` button in a row twice as tall came out as a wide, thin capsule with a small
    /// `×` adrift in it — drawn and looked at, which is the only way that shows. Stepping the
    /// control size instead keeps the bezel in proportion; three steps for seven scales is as
    /// close as AppKit's own sizes allow.
    var buttonControlSize: NSControl.ControlSize {
        switch scale {
        case ..<1.25: .small
        case ..<1.75: .regular
        default: .large
        }
    }

    /// Whether the row's `×` can carry a bezel at this size.
    ///
    /// The bezel is the one thing in a row with a floor of its own. Going up, AppKit refuses
    /// to draw it taller than its control size; going down it refuses to draw it smaller at
    /// all, and draws it *larger than the box it was given* — at half size that put a bezel
    /// 16 points tall in a 13-point frame inside a 10-point row, so the `×` of one row
    /// overlapped the `×` of the next. Drawn and looked at, like the failure at the other end.
    ///
    /// Below the size where the smallest bezel fits, the button keeps everything that makes
    /// it a button — its box, its click, its place at the end of the row — and gives up the
    /// bezel alone. The alternative was to stop the row shrinking at the bezel's floor, which
    /// at half size meant rows 16 points tall instead of 10: the setting would have stopped
    /// working well before the size it offers.
    ///
    /// Measured against a real button rather than a threshold written here, so a macOS that
    /// changes its metrics moves this with it.
    var buttonHasBezel: Bool {
        Self.borderedButtonSize(font: buttonFont, controlSize: buttonControlSize).height <= rowHeight
    }

    /// Below this a shortened name says nothing useful, and a single initial takes over.
    /// Kept small on purpose: a truncated `AGENTS…CLAUDE.md` still identifies a session.
    var minimumTitleWidth: CGFloat { points(52) }

    /// Breathing room inside the hover wash.
    var hoverPadding: CGFloat { points(4) }

    /// Three characters, always — the longest value the timer can print. Reserved in every
    /// row so the lamp and everything after it stand in a straight column.
    ///
    /// Measured through a label at this style's own font, which is why it cannot be a stored
    /// constant: the first scale to ask would have fixed the answer for every scale after it.
    var timerWidth: CGFloat { labelWidth(of: "99d", font: timerFont) }

    // MARK: - The list

    var rowSpacing: CGFloat { points(4) }
    /// The gap above the first row and below the last. Read by the widget's self-sizing
    /// height as well, which is why there is one of these and not one per reader.
    var listVerticalPadding: CGFloat { points(6) }

    /// The gap above and below the separator that introduces the account usage block.
    var usageDividerGap: CGFloat { points(4) }
    /// The separator itself, and the whole band it occupies. A hairline stays a hairline at
    /// every scale: it is a line, and a thicker one would read as a rule rather than a seam.
    var usageDividerHeight: CGFloat { 2 * usageDividerGap + 1 }

    // MARK: - The hover card

    var hoverCardPadding: CGFloat { points(8) }
    /// How wide the card is allowed to grow. Scaled with its own text, so a card holds about
    /// the same number of words per line whatever size it is drawn at.
    var hoverCardMaximumWidth: CGFloat { points(340) }

    // MARK: - The empty state

    var emptyStateIconPointSize: CGFloat { points(18) }
    var emptyStateIconGap: CGFloat { points(9) }
    var emptyStateLineGap: CGFloat { points(3) }

    /// The smallest the widget may be dragged to, and the size a first launch opens at.
    ///
    /// A function of the style rather than a constant, because it is the room the empty state
    /// needs: at twice the size that state no longer fits in 56 points, and a floor that
    /// stayed put would have clipped the one view whose whole job is to explain an empty
    /// widget.
    var minimumWindowSize: NSSize {
        NSSize(width: points(200), height: points(56))
    }
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
