import AppKit

/// The panel every surface in this app sits on: the widget itself and the hover card.
///
/// Liquid Glass on macOS 26, the frosted `.hudWindow` material before it, and a solid colour
/// when the person has asked the system to reduce transparency. Content goes into `content`:
/// on glass that is the glass's own content view, as the Dock holds its icons, so the system
/// keeps it legible; on the others a view above the surface, at full strength.
///
/// The chosen colour goes into the glass as a layer of its own rather than as the glass's
/// `tintColor`: measured on macOS 26.5, a tint left Midnight and Graphite the same grey.
@MainActor
final class Backdrop: NSView {
    let content = NSView()

    init(cornerRadius: CGFloat, tint: NSColor?, opacity: CGFloat, material: WidgetMaterial) {
        super.init(frame: .zero)
        let drawn = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .solid : material.drawn
        let surface: NSView
        switch drawn {
        case .solid:
            surface = NSView()
            surface.wantsLayer = true
            surface.layer?.cornerRadius = cornerRadius
            surface.layer?.backgroundColor = (tint ?? .windowBackgroundColor).cgColor
        case .glass, .clearGlass:
            surface = makeGlass(
                cornerRadius: cornerRadius, tint: tint, opacity: opacity, clear: drawn == .clearGlass,
                content: content)
        case .frosted:
            surface = makeFrost(cornerRadius: cornerRadius, tint: tint, opacity: opacity)
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        surface.pinToEdges(of: self)
        if content.superview == nil {
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            content.pinToEdges(of: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Liquid Glass holding `content`, or the frosted material on a system without it.
///
/// Frosted as well when built with an SDK older than macOS 26, which has no
/// `NSGlassEffectView`; Swift 6.2 is the compiler that SDK comes with.
@MainActor
private func makeGlass(cornerRadius: CGFloat, tint: NSColor?, opacity: CGFloat, clear: Bool, content: NSView)
    -> NSView
{
    #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = clear ? .clear : .regular
            glass.cornerRadius = cornerRadius
            if let tint {
                let colour = NSView()
                colour.wantsLayer = true
                colour.layer?.backgroundColor = glassTint(tint, opacity: opacity, clear: clear).cgColor
                colour.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(colour)
                colour.pinToEdges(of: content)
            }
            glass.contentView = content
            return glass
        }
    #endif
    return makeFrost(cornerRadius: cornerRadius, tint: tint, opacity: opacity)
}

@MainActor
private func makeFrost(cornerRadius: CGFloat, tint: NSColor?, opacity: CGFloat) -> NSView {
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
    return frost
}

/// How much of the theme's colour the glass takes: half at full opacity, a quarter on clear
/// glass, and less as the opacity slider goes down, so lower is clearer glass. A hint, as the
/// Dock's, not a coat of paint — the text on glass is not drawn for this colour.
func glassTint(_ colour: NSColor, opacity: CGFloat, clear: Bool = false) -> NSColor {
    colour.withAlphaComponent(opacity * (clear ? 0.25 : 0.5))
}

/// A backdrop of `material`, or of the theme in use's when none is named.
@MainActor
func makeBackdrop(
    cornerRadius: CGFloat, tint: NSColor? = nil, opacity: CGFloat = 1, material: WidgetMaterial? = nil
) -> Backdrop {
    Backdrop(cornerRadius: cornerRadius, tint: tint, opacity: opacity, material: material ?? WidgetMaterial.current)
}

/// The widget's own backdrop. On glass `background` is what the text is drawn for
/// (`WidgetMaterial.textBackground`), and the glass takes the colour of the theme in use.
@MainActor
func makeBackgroundView(for background: WidgetBackground, opacity: CGFloat) -> Backdrop {
    let tint =
        WidgetMaterial.current.drawn.needsLiquidGlass ? WidgetTheme.active.widgetBackground.color : background.color
    return makeBackdrop(cornerRadius: WidgetStyle.windowCornerRadius, tint: tint, opacity: opacity)
}
