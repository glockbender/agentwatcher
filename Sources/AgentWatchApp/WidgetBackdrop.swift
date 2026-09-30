import AppKit

/// The panel every surface in this app sits on: the widget itself and the hover card.
///
/// Liquid Glass on macOS 26 — with the content inside the glass, as the Dock holds its icons, so
/// the system keeps it legible — the frosted `.hudWindow` material before it, and a solid colour
/// when the person has asked the system to reduce transparency. Content goes into `content`.
@MainActor
final class Backdrop: NSView {
    private(set) var content: NSView = NSView()

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
            guard #available(macOS 26.0, *) else {
                fallthrough
            }
            let glass = NSGlassEffectView()
            glass.style = drawn == .clearGlass ? .clear : .regular
            glass.cornerRadius = cornerRadius
            if let tint {
                let colour = NSView()
                colour.wantsLayer = true
                colour.layer?.backgroundColor =
                    tint.withAlphaComponent(opacity * (drawn == .clearGlass ? glassTint / 2 : glassTint)).cgColor
                colour.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(colour)
                colour.pinToEdges(of: content)
            }
            glass.contentView = content
            surface = glass
        case .frosted:
            let frost = NSVisualEffectView()
            frost.material = .hudWindow
            frost.blendingMode = .behindWindow
            // Frosted whether or not the application is active, which for an accessory
            // application is never.
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
        addSubview(surface)
        surface.pinToEdges(of: self)
        if content.superview == nil {
            content = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// How much of the theme's colour the glass takes at full opacity; the opacity slider scales it,
/// so lower is clearer glass. A hint, as the Dock's, not a coat of paint.
var glassTint: CGFloat { WidgetTheme.motion.glassTint }

@MainActor
func makeBackdrop(cornerRadius: CGFloat, tint: NSColor? = nil, opacity: CGFloat = 1) -> Backdrop {
    Backdrop(cornerRadius: cornerRadius, tint: tint, opacity: opacity, material: WidgetMaterial.current)
}

/// The widget's own backdrop: the panel, carrying the chosen colour.
@MainActor
func makeBackgroundView(for background: WidgetBackground, opacity: CGFloat) -> Backdrop {
    let tint =
        WidgetMaterial.current.drawn.needsLiquidGlass ? WidgetTheme.active.widgetBackground.color : background.color
    return makeBackdrop(cornerRadius: WidgetStyle.windowCornerRadius, tint: tint, opacity: opacity)
}
