import AgentWatchCore
import AppKit

/// The real application icons for the agents, taken from the installed apps rather than
/// approximated with emoji.
///
/// The icon is a display concern only. It deliberately does not reuse
/// `AgentSource.desktopBundleIdentifier`, which answers a different question — which app's
/// termination closes a session. Claude Code runs in a terminal, so quitting Claude.app
/// must never close a Claude session, even though its icon is the right one to show.
@MainActor
enum AgentIcon {
    static let size = NSSize(width: 15, height: 15)

    private static var cache: [AgentSource: NSImage] = [:]

    /// Bundle identifiers used purely to borrow an icon.
    private static func iconBundleIdentifier(for source: AgentSource) -> String {
        switch source {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
    }

    /// Brand colours, used only when the application is not installed.
    private static func fallbackColor(for source: AgentSource) -> NSColor {
        switch source {
        case .claude: NSColor(calibratedRed: 0.85, green: 0.44, blue: 0.28, alpha: 1)
        case .codex: NSColor(calibratedWhite: 0.20, alpha: 1)
        }
    }

    static func image(for source: AgentSource) -> NSImage {
        if let cached = cache[source] {
            return cached
        }

        let image = applicationIcon(for: source) ?? fallbackIcon(for: source)
        image.size = size
        cache[source] = image
        return image
    }

    static func name(for source: AgentSource) -> String {
        source == .claude ? "Claude Code" : "Codex"
    }

    private static func applicationIcon(for source: AgentSource) -> NSImage? {
        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: iconBundleIdentifier(for: source)
            )
        else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    /// A plain brand-coloured disc. Enough to keep the two sources apart when neither
    /// desktop application is installed, which is normal for a terminal-only setup.
    private static func fallbackIcon(for source: AgentSource) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        fallbackColor(for: source).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        image.unlockFocus()
        return image
    }
}

/// Where the session runs. System symbols rather than the `⌘` and `⌨` characters: at row
/// size the characters read as decoration, and `terminal` is unmistakable.
@MainActor
enum SessionClientIcon {
    static func image(for clientKind: SessionClientKind) -> NSImage? {
        // Solid against a frame. Both were outlined rectangles before, and at 11 points the
        // `>_` inside one of them was too small to be the whole difference.
        let symbolName = clientKind == .desktop ? "macwindow" : "terminal.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: name(for: clientKind))
        image?.isTemplate = true
        return image
    }

    static func name(for clientKind: SessionClientKind) -> String {
        clientKind == .desktop ? "Desktop" : "CLI"
    }
}

/// What a session is doing, as symbols rather than emoji.
///
/// At row size the emoji were the least legible thing in the widget, and they cannot take
/// the row's foreground colour, so they stayed bright against a dimmed background.
@MainActor
enum ActivityIcon {
    static let size = NSSize(width: 12, height: 12)

    static func image(for kind: ActivityKind) -> NSImage? {
        let image = NSImage(
            systemSymbolName: symbolName(for: kind),
            accessibilityDescription: name(for: kind, count: 1)
        )
        image?.isTemplate = true
        return image
    }

    /// `chevron.right.square` for a shell rather than `terminal`, which is already the
    /// client icon for a session running in one — two terminals in a row would say two
    /// different things with the same picture.
    private static func symbolName(for kind: ActivityKind) -> String {
        switch kind {
        case .subagent: "person.2.fill"
        case .shell: "chevron.right.square"
        case .backgroundTask: "clock.arrow.circlepath"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .advisor: "lightbulb"
        case .tool: "wrench.and.screwdriver.fill"
        }
    }

    /// A count and what it counts, for the hover card: `2 shell commands`. The number is in
    /// it because the number beside the symbol is exactly what raises the question.
    ///
    /// The card puts "waiting on" in front of the whole list, once — see `activitiesText`.
    ///
    /// Compaction is the one entry with no number, for the same reason the row shows none: a
    /// session compacts one context at a time, so the digit never varies and `1 compacting
    /// context` only read as broken English.
    nonisolated static func name(for kind: ActivityKind, count: Int) -> String {
        switch kind {
        // No number, for the same reason compaction has none: the turn waits on one advisor
        // call at a time, so the digit would never vary.
        case .advisor: "asking the advisor"
        case .compaction: "compacting context"
        case .subagent: "\(count) \(count == 1 ? "subagent" : "subagents")"
        case .shell: "\(count) \(count == 1 ? "shell command" : "shell commands")"
        case .backgroundTask: "\(count) \(count == 1 ? "background task" : "background tasks")"
        case .tool: "\(count) \(count == 1 ? "tool call" : "tool calls")"
        }
    }
}
