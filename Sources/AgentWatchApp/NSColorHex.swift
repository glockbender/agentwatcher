import AppKit

extension NSColor {
    /// `#RRGGBB`, or nothing when the colour cannot be resolved into one.
    ///
    /// The conversion is not optional politeness: a system colour is a catalog colour with no
    /// components of its own, and asking one for `redComponent` raises rather than returns.
    var srgbHex: String? {
        guard let color = usingColorSpace(.sRGB) else {
            return nil
        }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(color.redComponent),
            channel(color.greenComponent),
            channel(color.blueComponent)
        )
    }

    /// `#RRGGBB`, with `AA` after it for a colour that is not opaque: for the marks a theme may
    /// draw translucent, such as secondary text on a dark background.
    var srgbHexWithAlpha: String? {
        guard let hex = srgbHex, let alpha = usingColorSpace(.sRGB)?.alphaComponent else {
            return nil
        }
        let byte = Int((alpha * 255).rounded())
        return byte == 255 ? hex : hex + String(format: "%02X", byte)
    }

    /// Reads `#RRGGBB` or `#RRGGBBAA`, and nothing else. Written by this app and, when it goes
    /// wrong, by a person editing the file, so the only sensible answer to anything else is `nil`.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = Int(digits, radix: 16) else {
            return nil
        }
        let rgb = digits.count == 8 ? value >> 8 : value
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: digits.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
        )
    }

    /// A fixed colour from its `#RRGGBB` spelling, for the values written into the source.
    /// Distinct from `init?(hex:)`, which reads what a person may have typed: a literal is
    /// checked when the tests run, and a failure would mean the source is wrong.
    convenience init(sRGB hex: String) {
        guard let color = NSColor(hex: hex) else {
            preconditionFailure("not a colour: \(hex)")
        }
        self.init(
            srgbRed: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: 1
        )
    }
}
