import AppKit

/// The menu's summary line with the agents' figure beside it.
///
/// A section header has no room for a second label, so while the figure is shown the header is
/// drawn by this view instead, and must not look any different. Measured on macOS 27.2 against
/// a real menu, in light and dark, at 2x: with the font, insets, height and colour below, the
/// two captures matched to the pixel. The figure is the same grey in the regular weight, so it
/// reads as a note on the line rather than part of it.
final class MenuSummaryView: NSView {
    static let phraseFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let figureFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let height: CGFloat = 24
    static let textLeft: CGFloat = 16
    static let textTop: CGFloat = 7
    static let textRight: CGFloat = 14

    private let phrase = NSTextField(labelWithString: "")
    private let figure = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.height))
        autoresizingMask = [.width]
        for field in [phrase, figure] {
            field.textColor = .tertiaryLabelColor
            field.lineBreakMode = .byClipping
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        phrase.font = Self.phraseFont
        figure.font = Self.figureFont
        figure.alignment = .right
        NSLayoutConstraint.activate([
            phrase.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeft),
            phrase.topAnchor.constraint(equalTo: topAnchor, constant: Self.textTop),
            figure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.textRight),
            figure.firstBaselineAnchor.constraint(equalTo: phrase.firstBaselineAnchor),
            figure.leadingAnchor.constraint(greaterThanOrEqualTo: phrase.trailingAnchor, constant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The phrase stays the one `MenuBarSummaryText` writes; the figure is a separate label with
    /// a sentence of its own for VoiceOver.
    func show(phrase text: String, figure figureText: String, spoken: String) {
        phrase.stringValue = text
        figure.stringValue = figureText
        figure.setAccessibilityLabel(spoken)
    }

    var phraseText: String { phrase.stringValue }
    var figureText: String { figure.stringValue }
}
