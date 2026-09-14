import AppKit

/// What the widget shows when no session is running.
///
/// Its own file beside `HUDSessionListView`, which is the other thing the widget's body can
/// be. The two are swapped into the same container and are read as a pair.
@MainActor
final class HUDEmptyStateView: NSView {
    /// - Parameter complaint: the one thing the widget is allowed to ask for — that some
    ///   agent is able to report to it at all. `nil` when one already can, and then the
    ///   widget says nothing about the rest: running only Claude on a machine that also has
    ///   Codex is a decision, not a half-finished setup.
    init(
        background: WidgetBackground,
        backgroundOpacity: CGFloat,
        style: WidgetStyle = .standard,
        complaint: String? = nil
    ) {
        super.init(frame: .zero)
        let effectView = makeBackgroundView(for: background, opacity: backgroundOpacity)

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "circle.grid.2x2.fill",
            accessibilityDescription: nil
        )
        icon.contentTintColor = background.secondaryForegroundColor
        icon.symbolConfiguration = .init(pointSize: style.emptyStateIconPointSize, weight: .medium)

        let title = NSTextField(labelWithString: "Agent Watch")
        title.font = style.emptyTitleFont
        title.textColor = background.foregroundColor

        let subtitle = NSTextField(labelWithString: complaint ?? "No active sessions")
        subtitle.font = style.emptySubtitleFont
        // An empty widget that cannot explain itself is the worst state this app has, so when
        // nothing can report to it the line says that instead of the ordinary "no sessions" —
        // and says it in the colour of something to act on.
        subtitle.textColor =
            complaint == nil ? background.secondaryForegroundColor : background.foregroundColor
        // Measured, not assumed: with the label's default compression resistance, a sentence
        // long enough to be useful pushed the whole widget wider than the width it was given.
        // Wrapping to two lines and yielding first is what keeps the window the size a person
        // chose.
        subtitle.usesSingleLineMode = false
        subtitle.maximumNumberOfLines = 2
        subtitle.cell?.wraps = true
        subtitle.cell?.isScrollable = false
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = style.emptyStateLineGap

        let contentStack = NSStackView(views: [icon, textStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = style.emptyStateIconGap
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: effectView.leadingAnchor, constant: style.contentInset),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: effectView.trailingAnchor, constant: -style.contentInset),
            contentStack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        addSubview(effectView)
        effectView.pinToEdges(of: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
