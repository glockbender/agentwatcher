import AgentWatchCore
import AppKit
import SwiftUI

// The theme editor's examples: each is the real view the app draws, given the look being
// edited rather than the one on screen, so what the page shows is what the theme will do.

/// One lamp on a patch of the widget's background, moving as it will in a row.
struct LampSwatch: NSViewRepresentable {
    static let size = NSSize(width: 40, height: 22)
    let phase: SessionPhase
    let look: WidgetTheme.Look

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 5
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        holder.layer?.backgroundColor = look.widgetBackground.color.cgColor
        holder.subviews.forEach { $0.removeFromSuperview() }
        let lamp = SessionLampView(
            appearance: SessionLamp.appearance(
                for: SampleSession.make(id: "lamp:\(phase.rawValue)", phase: phase), scheme: look.lampScheme),
            diameter: 12
        )
        lamp.frame.origin = NSPoint(x: (Self.size.width - 12) / 2, y: (Self.size.height - 12) / 2)
        holder.addSubview(lamp)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        Self.size
    }
}

/// A few rows of the widget, in three phases, on the panel the look describes.
struct ThemeRowsPreview: NSViewRepresentable {
    static let height: CGFloat = 86
    let look: WidgetTheme.Look
    let layout: RowLayout

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ holder: NSView, context: Context) {
        holder.subviews.forEach { $0.removeFromSuperview() }
        let background = look.widgetBackground
        let panel = makeBackdrop(
            cornerRadius: WidgetStyle.windowCornerRadius, tint: background.color, opacity: look.widgetOpacity,
            material: look.widgetMaterial)
        panel.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(panel)
        panel.pinToEdges(of: holder)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = WidgetStyle.standard.rowSpacing
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.appearance = background.controlAppearance
        holder.addSubview(stack)
        stack.pinToEdges(of: holder)
        for phase in [SessionPhase.waitingForUser, .executing, .completed] {
            let snapshot = SampleSession.make(id: "theme:\(phase.rawValue)", phase: phase)
            let row = HUDSessionRowView(
                snapshot: snapshot,
                now: snapshot.lastObservedAt.addingTimeInterval(4),
                background: background,
                lampScheme: look.lampScheme,
                layout: layout,
                onFocus: {},
                dismissal: phase == .completed ? .now : .notOffered(until: .distantFuture),
                onRemove: {}
            )
            row.setFlexibleText(
                layout.flexible.flatMap { rowPartText($0, for: snapshot, layout: layout) }, display: .fullName)
            stack.addArrangedSubview(row)
        }
    }
}

/// The menu bar icon in both of its styles, on a dark bar and on a light one, with the counts
/// changing every few seconds so the swell and the fades can be seen.
struct MenuBarIconPreview: NSViewRepresentable {
    static let height: CGFloat = 2 * MenuBarIconMetrics.barHeight + 8
    let look: WidgetTheme.Look

    func makeNSView(context: Context) -> MenuBarIconPreviewView {
        MenuBarIconPreviewView()
    }

    func updateNSView(_ view: MenuBarIconPreviewView, context: Context) {
        view.look = look
    }
}

@MainActor
final class MenuBarIconPreviewView: NSView {
    /// A made-up day: something waiting, work under way, a turn done, a few idle — and then one
    /// answered, one finished.
    static let counts: [SessionAttentionCounts] = [
        SessionAttentionCounts(needsPerson: 1, working: 3, done: 1, quiet: 6),
        SessionAttentionCounts(needsPerson: 2, working: 3, done: 1, quiet: 5),
        SessionAttentionCounts(needsPerson: 1, working: 3, done: 2, quiet: 5),
        SessionAttentionCounts(needsPerson: 0, working: 3, done: 3, quiet: 5),
    ]

    var look = WidgetTheme.active {
        didSet { if look != oldValue { redraw() } }
    }
    private var icons: [(view: MenuBarIconView, style: MenuBarIconStyle)] = []
    private var step = 0
    private var timer: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: MenuBarIconPreview.height))
        for (row, dark) in [true, false].enumerated() {
            for (column, style) in [MenuBarIconStyle.sphere, .counts].enumerated() {
                let bar = NSView(
                    frame: NSRect(
                        x: CGFloat(column) * 110, y: CGFloat(1 - row) * (MenuBarIconMetrics.barHeight + 8),
                        width: 100, height: MenuBarIconMetrics.barHeight))
                bar.wantsLayer = true
                bar.layer?.cornerRadius = 5
                bar.layer?.backgroundColor = NSColor(white: dark ? 0.16 : 0.93, alpha: 1).cgColor
                bar.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // The icon lays itself out against the view that holds its button, as it does in
                // the status bar; this stands in for both.
                let button = NSView(frame: bar.bounds)
                bar.addSubview(button)
                let icon = MenuBarIconView()
                button.addSubview(icon)
                icon.fill(button)
                addSubview(bar)
                icons.append((icon, style))
            }
        }
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 210, height: MenuBarIconPreview.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            return
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step = (self.step + 1) % Self.counts.count
                self.redraw()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func redraw() {
        let cells = MenuBarIconCell.cells(for: Self.counts[step], look: look)
        for (icon, style) in icons {
            icon.show(cells, as: style, motion: look.sphereMotion)
        }
    }
}

/// A menu with a few session lines in it, their marks drawn and moved as the theme says.
struct MenuLinesPreview: NSViewRepresentable {
    static let height: CGFloat = CGFloat(MenuLinesPreviewView.lines.count) * 22 + 12
    static let width: CGFloat = 220
    let look: WidgetTheme.Look

    func makeNSView(context: Context) -> MenuLinesPreviewView {
        MenuLinesPreviewView()
    }

    func updateNSView(_ view: MenuLinesPreviewView, context: Context) {
        view.look = look
    }
}

@MainActor
final class MenuLinesPreviewView: NSVisualEffectView {
    static let lines: [(String, SessionPhase)] = [
        ("Rewrite the ingress", .waitingForUser),
        ("Port the probe", .failed),
        ("Monitoring AI sessions", .executing),
        ("Docs for the project", .completed),
        ("Background script", .idle),
    ]

    var look = WidgetTheme.active {
        didSet {
            guard look != oldValue else { return }
            drawFrame()
            runTimerIfMoving()
        }
    }
    private var marks: [NSImageView] = []
    private var timer: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuLinesPreview.width, height: MenuLinesPreview.height))
        material = .menu
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        for (index, (title, _)) in Self.lines.enumerated() {
            let y = MenuLinesPreview.height - 6 - CGFloat(index + 1) * 22
            let mark = NSImageView(frame: NSRect(x: 14, y: y + 2, width: 18, height: 18))
            mark.imageScaling = .scaleProportionallyDown
            addSubview(mark)
            marks.append(mark)
            let label = NSTextField(labelWithString: title)
            label.font = .menuFont(ofSize: 0)
            label.frame = NSRect(x: 38, y: y + 2, width: MenuLinesPreview.width - 46, height: 18)
            addSubview(label)
        }
        drawFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: MenuLinesPreview.width, height: MenuLinesPreview.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        runTimerIfMoving()
    }

    /// Frames only while something moves and the preview is in a window: a still mark drawn
    /// again a dozen times a second would be work with nothing to show for it.
    private func runTimerIfMoving() {
        timer?.invalidate()
        timer = nil
        let moving = Self.lines.contains { look.menuMarkStyle(for: $0.1).motion != .steady }
        guard window != nil, moving else {
            return
        }
        let timer = Timer(timeInterval: 1 / MenuMarkAnimator.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drawFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func drawFrame() {
        let now = CACurrentMediaTime()
        for (mark, (_, phase)) in zip(marks, Self.lines) {
            mark.image = MenuMarkAnimator.frame(
                of: look.menuMarkStyle(for: phase), attention: phase.attention, at: now)
        }
    }
}
