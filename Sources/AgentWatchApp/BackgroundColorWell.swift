import AppKit

/// The colour well for a background of the person's own.
///
/// Two differences from the lamp's wells, and both are in `activate`, which is what a click on
/// the well calls.
///
/// It opens the colour panel on the wheel, because that is what the owner asked a background to
/// be picked on. Turned there on every opening rather than once: the panel is one for the whole
/// app, the lamp's wells share it, and it reopens on whichever page it was last left at.
///
/// And a click is a choice. A press on a swatch in the palette selects that background, and a
/// press on this well selects the colour it shows, before the wheel has been touched — without
/// that, opening the wheel would leave the widget on the preset until the pointer moved.
///
/// Made with `init()`, never `init(style:)`. Measured: that one is a factory that hands back a
/// plain `NSColorWell` whatever class it is called on, so the override below never ran — the
/// click opened the panel on its last page and chose nothing — and reading a property of the
/// subclass crashed the process. `init()` gives the default style, the lamp wells' own.
final class BackgroundColorWell: NSColorWell {
    override func activate(_ exclusive: Bool) {
        NSColorPanel.shared.mode = .wheel
        super.activate(exclusive)
        sendAction(action, to: target)
    }
}
