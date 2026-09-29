import AppKit

/// The panel every surface in this app sits on: the widget itself and the hover card.
///
/// Liquid Glass on macOS 26, the frosted `.hudWindow` material before it, and a solid colour
/// when the person has asked the system to reduce transparency. Content is added to the
/// returned view and sits above the surface at full strength.
///
/// The chosen colour goes into the glass as a layer of its own rather than as the glass's
/// `tintColor`: measured on macOS 26.5, a tint left Midnight and Graphite the same grey, and the
/// colour is what the row's text colours were chosen against.
@MainActor
func makeBackdrop(
    cornerRadius: CGFloat, tint: NSColor? = nil, opacity: CGFloat = 1, material: WidgetMaterial = .glass
) -> NSView {
    let container = NSView()
    let surface: NSView
    let drawn = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .solid : material.drawn
    switch drawn {
    case .solid:
        surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = cornerRadius
        surface.layer?.backgroundColor = (tint ?? .windowBackgroundColor).cgColor
    case .glass, .clearGlass:
        surface = makeGlass(cornerRadius: cornerRadius, tint: tint, opacity: opacity, clear: drawn == .clearGlass)
    case .frosted:
        let frost = NSVisualEffectView()
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        // Frosted whether or not the application is active, which for an accessory application
        // is never.
        frost.state = .active
        frost.alphaValue = opacity
        frost.wantsLayer = true
        frost.layer?.cornerRadius = cornerRadius
        frost.layer?.masksToBounds = true
        if let tint {
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = tint.cgColor
            overlay.translatesAutoresizingMaskIntoConstraints = false
            frost.addSubview(overlay)
            overlay.pinToEdges(of: frost)
        }
        surface = frost
    }
    surface.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(surface)
    surface.pinToEdges(of: container)
    return container
}

/// Liquid Glass, or the frosted material on a system without it.
///
/// Frosted as well when built with an SDK older than macOS 26, which has no
/// `NSGlassEffectView`; Swift 6.2 is the compiler that SDK comes with.
@MainActor
private func makeGlass(cornerRadius: CGFloat, tint: NSColor?, opacity: CGFloat, clear: Bool) -> NSView {
    #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = clear ? .clear : .regular
            glass.cornerRadius = cornerRadius
            if let tint {
                let colour = NSView()
                colour.wantsLayer = true
                colour.layer?.backgroundColor = glassTint(tint, opacity: opacity, clear: clear).cgColor
                glass.contentView = colour
            }
            return glass
        }
    #endif
    return makeBackdrop(cornerRadius: cornerRadius, tint: tint, opacity: opacity, material: .frosted)
}

/// How much of the chosen colour the glass carries.
///
/// The opacity slider decides how far the desktop shows through, but never below the floor:
/// under that the text, drawn for the chosen colour, is left to whatever wallpaper is behind.
/// Clear glass is allowed less colour, which is what makes it clear.
func glassTint(_ colour: NSColor, opacity: CGFloat, clear: Bool = false) -> NSColor {
    colour.withAlphaComponent(clear ? max(0.25, opacity * 0.6) : max(glassTintFloor, opacity))
}

let glassTintFloor: CGFloat = 0.45

/// The widget's own backdrop: the panel, carrying the chosen colour.
@MainActor
func makeBackgroundView(for background: WidgetBackground, opacity: CGFloat) -> NSView {
    makeBackdrop(
        cornerRadius: WidgetStyle.windowCornerRadius, tint: background.color, opacity: opacity,
        material: WidgetMaterial.current)
}
