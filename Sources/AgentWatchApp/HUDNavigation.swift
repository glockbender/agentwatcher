import AppKit

@MainActor
struct HUDNavigation {
    let projects: () -> Void
    let settings: () -> Void

    /// Place both controls above the resize strip. The remaining footer is a drag surface.
    @discardableResult
    func install(in backdrop: Backdrop, background: WidgetBackground, style: WidgetStyle) -> NSLayoutYAxisAnchor {
        let buttons = NSStackView(views: [
            HUDActionButton("Projects", background: background, style: style, perform: projects),
            HUDActionButton("Settings", background: background, style: style, perform: settings),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = style.elementSpacing
        buttons.translatesAutoresizingMaskIntoConstraints = false
        backdrop.content.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: max(7, style.contentInset)),
            buttons.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -7),
            buttons.heightAnchor.constraint(equalToConstant: style.navigationHeight - 7),
        ])
        return buttons.topAnchor
    }
}

@MainActor
private final class HUDActionButton: NSButton {
    private let perform: () -> Void

    init(_ title: String, background: WidgetBackground, style: WidgetStyle, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        controlSize = .small
        attributedTitle = NSAttributedString(
            string: title, attributes: [.font: style.usageFont, .foregroundColor: background.foregroundColor])
        toolTip = "Open " + title
        setAccessibilityLabel("Open " + title)
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func pressed() { perform() }
}
