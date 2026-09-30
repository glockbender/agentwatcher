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

    /// Reads `#RRGGBB`, and nothing else. Written by this app and, when it goes wrong, by a
    /// person editing the file, so the only sensible answer to anything else is `nil`.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return nil
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
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
