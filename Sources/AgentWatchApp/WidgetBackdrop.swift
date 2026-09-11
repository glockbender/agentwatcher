import AppKit

/// The frosted panel every surface in this app sits on: the widget itself and the hover card.
///
/// One function rather than the same five lines in each, which is what they were. The two
/// differ only in how round they are and how far they fade.
@MainActor
func makeBackdrop(cornerRadius: CGFloat, opacity: CGFloat = 1) -> NSVisualEffectView {
    let backdrop = NSVisualEffectView()
    backdrop.material = .hudWindow
    backdrop.blendingMode = .behindWindow
    // Frosted whether or not the application is active, which for an accessory application
    // is never.
    backdrop.state = .active
    backdrop.alphaValue = opacity
    backdrop.wantsLayer = true
    backdrop.layer?.cornerRadius = cornerRadius
    backdrop.layer?.masksToBounds = true
    return backdrop
}

/// The widget's own backdrop: the frosted panel with the chosen colour laid over it.
///
/// The tint alone cannot make the widget transparent — the frosted layer underneath is opaque
/// at every slider position — so both fade together inside one view, and the content sits
/// above them at full strength so the text stays legible.
@MainActor
func makeBackgroundView(for background: WidgetBackground, opacity: CGFloat) -> NSView {
    let container = NSView()

    let backdrop = makeBackdrop(cornerRadius: WidgetStyle.windowCornerRadius, opacity: opacity)
    backdrop.translatesAutoresizingMaskIntoConstraints = false

    let colorOverlay = NSView()
    colorOverlay.wantsLayer = true
    colorOverlay.layer?.backgroundColor = background.color.cgColor
    colorOverlay.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(colorOverlay)

    container.addSubview(backdrop)
    backdrop.pinToEdges(of: container)
    colorOverlay.pinToEdges(of: backdrop)
    return container
}
