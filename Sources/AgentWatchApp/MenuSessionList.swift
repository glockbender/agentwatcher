import AppKit
import Carbon.HIToolbox

/// The menu's sessions: one line per session, as many as the setting shows, and a scroll for
/// the rest.
///
/// A menu has no part that scrolls by itself — it scrolls as a whole, and only once it is
/// taller than its screen — so the list is one menu line holding a scroll view (ADR-0018).
/// Its lines draw themselves and answer the pointer: the trackpad's scroll, the hover and the
/// click were measured in a real menu on macOS 15.3.1. The arrows skip the list: a menu keeps
/// every arrow it can use, so no line inside the list ever sees one, and the list's menu line
/// has no action, which a menu reads as disabled and steps over (`docs/measurements.md`).
@MainActor
final class MenuSessionListView: NSView {
    /// The height of an ordinary menu line on the machine it was measured on.
    static let lineHeight: CGFloat = 22
    /// As narrow as the list may be when its titles are short.
    static let minimumWidth: CGFloat = 200

    let rows: [MenuSessionRowView]
    let scrollView = NSScrollView()
    /// Whether there are more lines than the list shows at once.
    let scrolls: Bool
    var onChoose: ((MenuSessionLine) -> Void)?

    init(lines: [MenuSessionLine], images: [NSImage?], visibleCount: Int) {
        let width = max(Self.minimumWidth, (lines.map(MenuSessionRowView.naturalWidth).max() ?? 0).rounded(.up))
        rows = zip(lines, images).enumerated().map { index, pair in
            MenuSessionRowView(
                line: pair.0, image: pair.1,
                frame: NSRect(x: 0, y: CGFloat(index) * Self.lineHeight, width: width, height: Self.lineHeight))
        }
        scrolls = lines.count > visibleCount
        let height = CGFloat(min(lines.count, visibleCount)) * Self.lineHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // As wide as the menu makes its widest line, from this width up.
        autoresizingMask = [.width]

        let document = FlippedView(
            frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(lines.count) * Self.lineHeight))
        document.autoresizingMask = [.width]
        for row in rows {
            row.list = self
            document.addSubview(row)
        }
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = scrolls
        // A list that shows every line has nothing to scroll, and a bounce would say it had.
        scrollView.verticalScrollElasticity = scrolls ? .automatic : .none
        scrollView.horizontalScrollElasticity = .none
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentMoved), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Sessions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// A scroll moves the lines under a still pointer, and a line's own tracking area says
    /// nothing until the pointer moves again: so the lit line is read from where the pointer
    /// is, not from the last line it entered.
    @objc private func contentMoved() {
        pointerMoved()
    }

    func pointerMoved() {
        let lit = window.map { rowIndex(at: $0.mouseLocationOutsideOfEventStream) } ?? nil
        for (index, row) in rows.enumerated() {
            row.isHovered = index == lit
        }
    }

    /// The line under a point in the window's coordinates, if the point is inside the list.
    func rowIndex(at pointInWindow: NSPoint) -> Int? {
        let clip = scrollView.contentView
        guard clip.bounds.contains(clip.convert(pointInWindow, from: nil)),
            let document = scrollView.documentView
        else {
            return nil
        }
        let index = Int((document.convert(pointInWindow, from: nil).y / Self.lineHeight).rounded(.down))
        return rows.indices.contains(index) ? index : nil
    }

    func choose(_ row: MenuSessionRowView) {
        guard row.line.isEnabled else {
            return
        }
        onChoose?(row.line)
    }

    /// An arrow can reach the list while the menu is already moving its highlight for that
    /// same arrow — seen on macOS 15.3.1 — so the list drops it rather than hand it on. Every
    /// other key goes up the responder chain, as it would without the list.
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            return
        default:
            super.keyDown(with: event)
        }
    }
}

/// One session's line in the menu's list, drawn the way a menu draws its own.
@MainActor
final class MenuSessionRowView: NSView {
    let line: MenuSessionLine
    /// The state's mark, which a theme may move: replaced a dozen times a second while the
    /// menu is open (`MenuMarkAnimator`).
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var isHovered = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }
    weak var list: MenuSessionListView?

    init(line: MenuSessionLine, image: NSImage?, frame: NSRect) {
        self.line = line
        self.image = image
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(line.title)
        setAccessibilityEnabled(line.isEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Lit only where a click would do something.
    var isLit: Bool {
        isHovered && line.isEnabled
    }

    override func mouseUp(with event: NSEvent) {
        list?.choose(self)
    }

    override func accessibilityPerformPress() -> Bool {
        list?.choose(self)
        return line.isEnabled
    }

    // MARK: - Drawing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        )
    }

    override func mouseEntered(with event: NSEvent) {
        list?.pointerMoved()
    }

    override func mouseExited(with event: NSEvent) {
        list?.pointerMoved()
    }

    override func draw(_ dirtyRect: NSRect) {
        let lit = isLit
        if lit {
            // Inset and rounded the way the system draws its own menu highlight.
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let font = NSFont.menuFont(ofSize: 0)
        // Secondary, not the disabled control colour: on the menu's own material that one all
        // but vanished, and a greyed line still says why it cannot be chosen.
        let colour: NSColor =
            lit ? .selectedMenuItemTextColor : line.isEnabled ? .labelColor : .secondaryLabelColor
        // Where the probe for the choice lines put it, beside the system's own lines.
        let textY = ((bounds.height - font.capHeight) / 2 - 3).rounded()
        if let image {
            let size = image.size
            image.draw(
                in: NSRect(
                    x: Self.stateColumnWidth, y: ((bounds.height - size.height) / 2).rounded(), width: size.width,
                    height: size.height),
                from: .zero, operation: .sourceOver, fraction: line.isEnabled ? 1 : 0.5)
        }
        NSAttributedString(string: line.title, attributes: [.font: font, .foregroundColor: colour])
            .draw(at: NSPoint(x: Self.textLeft, y: textY))
    }

    /// The column a menu keeps for checkmarks, which its own lines' pictures sit after.
    private static let stateColumnWidth: CGFloat = 23
    /// The mark is the state's symbol at 13 points, 16 wide, and six points of air after it.
    private static let textLeft: CGFloat = stateColumnWidth + 16 + 6
    private static let rightMargin: CGFloat = 20

    static func naturalWidth(of line: MenuSessionLine) -> CGFloat {
        textLeft + (line.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
            + rightMargin
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
