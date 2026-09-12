import AgentWatchCore
import AppKit

/// The one window where Agent Watch says what it has written into other programs.
///
/// This replaced a submenu whose every line was both the state and the switch. That worked
/// while there were four states; it stopped working once a line had to carry the sender's
/// path, the trust step Codex needs, and the difference between "installed" and "installed
/// and never heard from". A menu line has one line, and the answer stopped fitting on it.
///
/// So the window is mostly text, and that is the point rather than a shortcut. This app edits
/// files that belong to other programs, and a person is entitled to see which file, what is
/// in it, and what is left for them to do — before pressing anything, and without opening a
/// terminal.
@MainActor
final class ToolingWindowController: NSWindowController {
    /// Read from disk every time the window is shown, because these files belong to other
    /// programs and other people: a state cached here would describe the last time this app
    /// looked rather than what is there now.
    private let facts: () -> ToolingWindowFacts
    private let act: (ToolingPress) -> Void

    /// Flipped, because it is a scroll view's document: an unflipped one shorter than the
    /// window sinks to the bottom and leaves the slack above it.
    private let content = FlippedStackView()

    /// The action buttons, by what they act on. Reachable from the tests, which press them
    /// the way a person does.
    private(set) var actionButtons: [ToolingPress: NSButton] = [:]

    init(facts: @escaping () -> ToolingWindowFacts, act: @escaping (ToolingPress) -> Void) {
        self.facts = facts
        self.act = act

        let window = NSWindow(
            // Replaced by the content's own fitting size below; a window needs some rect to
            // be born with.
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            // Resizable since the content can outgrow a screen: five IDEs on this machine is
            // an ordinary number, and a window with a scroller a person cannot enlarge is
            // worse than one they can.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Watch Tooling"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        // In a scroll view rather than straight in the window, because the window is sized to
        // its content and the content has no upper bound: every JetBrains IDE on the machine
        // is a row. Without this, a person with five of them gets a window taller than their
        // screen, with the rows they came for below the bottom edge.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        window.contentView = scroll
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isShowing: Bool {
        window?.isVisible == true
    }

    /// Opens the window, or brings it forward if it is already open.
    ///
    /// Not a toggle: a settings window is closed with its own close button, and a menu line
    /// that sometimes closes it instead of showing it would need the person to know which of
    /// the two it is about to do.
    func present() {
        rebuild()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Rebuilt whole rather than patched. Every row can change when any one of them is
    /// pressed — installing points the sender link at this build, which is a line in every
    /// other row — and a window rebuilt from one reading of the disk cannot show two rows
    /// that disagree about the same file.
    func rebuild() {
        for view in content.views {
            content.removeView(view)
        }
        actionButtons.removeAll()

        let reading = facts()
        let sections = ToolingReport.sections(
            hookState: reading.hookState,
            statusLineState: { reading.statusLineState },
            hooksPath: reading.hooksPath,
            statusLinePath: reading.statusLinePath,
            idePlugins: reading.idePlugins,
            stagedPlugin: reading.stagedPlugin,
            idePluginDirectoryPath: reading.idePluginDirectoryPath
        )

        let rows = sections.flatMap(\.rows)
        // The rules are as wide as the widest thing they separate, measured from what is
        // actually there. A constant would decide the window's width instead and leave a
        // strip of empty window beside every control.
        let bodyWidth = max(Self.minimumBodyWidth, rows.map { Self.width(of: $0) }.max() ?? 0)

        for (index, section) in sections.enumerated() {
            if index > 0 {
                content.addView(Self.makeRule(width: bodyWidth), in: .top)
            }
            content.addView(Self.makeSectionTitle(section.title), in: .top)
            for row in section.rows {
                content.addView(makeRow(row, width: bodyWidth), in: .top)
            }
        }

        content.addView(Self.makeRule(width: bodyWidth), in: .top)
        content.addView(makeSenderNote(reading, width: bodyWidth), in: .top)

        // The trailing inset added by hand, and measured rather than assumed: a vertical
        // stack aligned to its leading edge pins nothing to the other one, so its fitting
        // width came out as the left inset plus the widest row and the buttons sat flush
        // against the window's edge. The container stretches the stack, so the extra width
        // lands where the missing margin belongs.
        let fitting = content.fittingSize
        let width = fitting.width + content.edgeInsets.right
        // The width is a floor as well as a size. Every label in here is pinned to the body
        // width, so a window dragged narrower than its content would put those constraints
        // against the one that ties the stack to the window — and the loser is the layout.
        window?.contentMinSize = NSSize(width: width, height: 200)
        window?.setContentSize(NSSize(width: width, height: min(fitting.height, Self.tallestUsefulWindow)))
    }

    /// As tall as the screen leaves room for, and no taller. Beyond this the rows are reached
    /// by scrolling, which is the one thing a window taller than the screen cannot offer.
    private static var tallestUsefulWindow: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.9
    }

    // MARK: - The rows

    private func makeRow(_ row: ToolingReportRow, width: CGFloat) -> NSView {
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addView(Self.makeTitle(row, width: width), in: .top)
        text.addView(Self.makeLabel(row.state, width: width), in: .top)
        for detail in row.details {
            text.addView(Self.makePath(detail, width: width), in: .top)
        }
        if let nextStep = row.nextStep {
            text.addView(Self.makeNextStep(nextStep, width: width), in: .top)
        }

        guard !row.actions.isEmpty else {
            return text
        }

        // The buttons beside the text rather than under it: a row is one thing, and a press
        // that sits below its own explanation reads as belonging to the row after it. Two of
        // them stack, because an IDE row offers a way in and a way to check it.
        let buttons = NSStackView(
            views: row.actions.map { action in
                let button = NSButton(title: action.title, target: self, action: #selector(actionPressed(_:)))
                button.bezelStyle = .rounded
                button.isEnabled = action.isEnabled
                button.toolTip = action.hint
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                actionButtons[action.press] = button
                return button
            }
        )
        buttons.orientation = .vertical
        buttons.alignment = .trailing
        buttons.spacing = 6

        let line = NSStackView(views: [text, buttons])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 16
        // The text takes the slack, so buttons form a column down the right edge instead of
        // stopping wherever each explanation happens to end.
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        return line
    }

    /// One line about the program every entry above actually runs.
    ///
    /// Its own note rather than a line inside each row: it is the same path in all of them,
    /// and the thing worth saying about it — that this build claimed it, and what happens if
    /// the link could not be made — is worth saying once.
    private func makeSenderNote(_ reading: ToolingWindowFacts, width: CGFloat) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.addView(
            Self.makeLabel("Sender", font: .systemFont(ofSize: 12, weight: .semibold), width: width),
            in: .top
        )
        stack.addView(Self.makePath(reading.senderPath, width: width), in: .top)
        if reading.senderIsTiedToThisBuild {
            stack.addView(
                Self.makeNextStep(
                    "The stable link could not be made, so the entries name this build directly. They stop "
                        + "working if this copy of Agent Watch is moved or deleted.",
                    width: width
                ),
                in: .top
            )
        }
        return stack
    }

    /// What a button does is looked up rather than carried on the button: `NSMenuItem` has a
    /// `representedObject` and `NSButton` has none, and the map the tests press through is
    /// already the answer.
    @objc private func actionPressed(_ sender: NSButton) {
        guard let press = actionButtons.first(where: { $0.value === sender })?.key else {
            return
        }
        // Nothing is rebuilt here: whoever performs the press says when the facts changed, and
        // the window is rebuilt from that one report. A second rebuild from this side read the
        // same disk twice for every press.
        act(press)
    }

    // MARK: - Pieces

    /// Wide enough that the longest sentence here wraps somewhere sensible rather than at
    /// whatever width the shortest state happens to need.
    private static let minimumBodyWidth: CGFloat = 380

    private static func width(of row: ToolingReportRow) -> CGFloat {
        // Measured from the state line alone. The explanations wrap and the paths are allowed
        // to, so neither should be able to push the window wider than a screen.
        min(520, makeLabel(row.state, width: 0).fittingSize.width)
    }

    /// A row's name, with a dot in front of it when the row is about something that can be
    /// running.
    ///
    /// The dot rather than a word, because it is the same fact on every IDE row and the eye
    /// takes a column of dots in one pass. It is never the only carrier: the row says "Not
    /// running" in words wherever that changes what can be done, so nothing here depends on
    /// telling two colours apart.
    private static func makeTitle(_ row: ToolingReportRow, width: CGFloat) -> NSTextField {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        guard let status = row.status else {
            return makeLabel(row.title, font: font, width: width)
        }
        let label = makeLabel("● \(row.title)", font: font, width: width)
        let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
        text.addAttribute(
            .foregroundColor,
            value: status == .running ? NSColor.systemGreen : NSColor.tertiaryLabelColor,
            range: NSRange(location: 0, length: 1)
        )
        label.attributedStringValue = text
        label.toolTip = toolingStatusHint(status)
        return label
    }

    private static func makeSectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        return label
    }

    private static func makeRule(width: CGFloat) -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: width).isActive = true
        return rule
    }

    private static func makeLabel(
        _ text: String,
        font: NSFont = .systemFont(ofSize: 12),
        width: CGFloat
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        // Selectable, so a path can be copied out of here instead of retyped. It is the only
        // reason a person would reach for a terminal after reading this window.
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        if width > 0 {
            label.preferredMaxLayoutWidth = width
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return label
    }

    private static func makePath(_ text: String, width: CGFloat) -> NSTextField {
        let label = makeLabel(text, font: .monospacedSystemFont(ofSize: 10, weight: .regular), width: width)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeNextStep(_ text: String, width: CGFloat) -> NSTextField {
        let label = makeLabel(text, width: width)
        // The one thing on the row that is addressed to the person rather than describing the
        // disk, so it is the one thing that is not grey.
        label.textColor = .labelColor
        return label
    }
}

/// One reading of everything the tooling window shows.
///
/// Taken in one go and handed over as a value, so every row in a rebuilt window describes the
/// same moment. Reading each answer where it is needed let a window show a state from before
/// a press beside one from after it.
@MainActor
struct ToolingWindowFacts {
    let hookState: (AgentSource) -> ToolingInstallationState
    let statusLineState: StatusLineState
    let hooksPath: (AgentSource) -> String
    let statusLinePath: String
    let senderPath: String
    /// The link could not be made, so the entries name this build's own binary. See
    /// `SenderLink`.
    let senderIsTiedToThisBuild: Bool
    /// Every JetBrains IDE on this machine and what is known about the plugin in each, found
    /// again on every opening: an IDE updated since the last one keeps its settings in a
    /// different directory, so a remembered answer would describe a plugin the new version
    /// never loaded.
    let idePlugins: [IDEPluginReading]
    let stagedPlugin: StagedIDEPlugin?
    let idePluginDirectoryPath: String

    /// What the window shows when the application that answers these questions has gone —
    /// which happens only while it is shutting down. Nothing is claimed and nothing is
    /// offered: an empty answer beats a stale one, and a button here would write files on
    /// behalf of an app that is no longer there.
    static let unavailable = ToolingWindowFacts(
        hookState: { _ in .unreadable },
        statusLineState: .unreadable,
        hooksPath: { _ in "" },
        statusLinePath: "",
        senderPath: "",
        senderIsTiedToThisBuild: false,
        idePlugins: [],
        stagedPlugin: nil,
        idePluginDirectoryPath: ""
    )
}
