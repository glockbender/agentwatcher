import AppKit

/// The changes since the running version, set as text for Sparkle's update window.
///
/// The window shows an attributed string in a plain text view, which draws no headings and no
/// list markers of its own. So the few shapes `CHANGELOG.md` uses are drawn here: a version
/// heading in bold with its date, a section name (`Added`, `Fixed`) in bold, a bullet as `•`.
/// Inside a line, Markdown keeps doing the rest — code, emphasis, links.
enum ChangelogText {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        var first = true
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }
            let (text, font, spaceBefore) = shape(of: line, body: body, bold: bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = first ? 0 : spaceBefore
            if text.hasPrefix("• ") {
                paragraph.headIndent = 12
            }
            let piece = NSMutableAttributedString(attributedString: inline(text))
            let whole = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.font, value: font, range: whole)
            piece.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
            // Markdown marks code and emphasis as intents, which a text view does not draw.
            piece.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue else {
                    return
                }
                let intent = InlinePresentationIntent(rawValue: raw)
                if intent.contains(.code) {
                    piece.addAttribute(
                        .font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                        range: range)
                } else if intent.contains(.stronglyEmphasized) {
                    piece.addAttribute(.font, value: bold, range: range)
                }
            }
            piece.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if !first {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(piece)
            first = false
        }
        return result
    }

    /// What a line says and how it is set: `## [0.4.0] - 2026-10-12` → "0.4.0 — 2026-10-12" in bold.
    private static func shape(of line: String, body: NSFont, bold: NSFont) -> (String, NSFont, CGFloat) {
        if line.hasPrefix("## ") {
            let heading = line.dropFirst(3)
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: " - ", with: " — ")
            return (heading, bold, 14)
        }
        if line.hasPrefix("### ") {
            return (String(line.dropFirst(4)), bold, 6)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return ("• " + line.dropFirst(2), body, 3)
        }
        return (line, body, 3)
    }

    /// Code, emphasis and links inside one line, or the line as it is when it does not parse.
    private static func inline(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text)
        }
        return NSAttributedString(parsed)
    }
}
