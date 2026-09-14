import AppKit

/// What to do with the hover card, given what just happened to the pointer or to the list.
enum HoverCardAction: Equatable {
    /// Nothing — by far the commonest answer, and the one that keeps a card alive while the
    /// list is rebuilt underneath it.
    case none
    /// Start the countdown. Nothing is shown until it finishes.
    case arm(sessionID: String)
    /// Put the card in front of this session's row, now.
    case present(sessionID: String)
    /// The pointer is still on this session, but the row it was on has been replaced: put the
    /// row's highlight back, and restate whatever the card is showing.
    case reattach(sessionID: String)
    /// Put the card away and stop waiting.
    case dismiss
}

/// When the hover card appears, stays and closes.
///
/// Kept apart from the card itself and free of any view, because this is where the mistakes
/// happen and a view is what makes them hard to check. Both of the ones below were found in
/// the running app rather than in a test:
///
/// - a rebuild hands the pointer a new view for the same session, and that view reports an
///   arrival although the pointer never moved. Re-arming on it restarted the half-second
///   countdown on every event, so on a busy session — the one most worth inspecting — the
///   card never appeared at all;
/// - a card stayed open above a session that had already left the list.
///
/// Its whole state is the session the pointer is on, so a test states a situation in one line
/// and reads the answer out of the returned action.
struct HoverCardState: Equatable {
    /// The session the pointer is on, or `nil` when it is on none.
    private(set) var hoveredSessionID: String?

    mutating func pointerEntered(sessionID: String) -> HoverCardAction {
        guard hoveredSessionID != sessionID else {
            return .none
        }
        hoveredSessionID = sessionID
        return .arm(sessionID: sessionID)
    }

    /// Reported by a row. Only the row the pointer is actually on may close the card: a row
    /// rebuilt behind the pointer reports its own exit on the way out, and acting on that
    /// would close the card under a pointer that never moved.
    mutating func pointerLeft(sessionID: String) -> HoverCardAction {
        guard hoveredSessionID == sessionID else {
            return .none
        }
        return pointerLeftWidget()
    }

    /// Reported by the widget itself, which is the one view that cannot miss the pointer
    /// leaving: a row replaced under a resting pointer never gets to report anything.
    mutating func pointerLeftWidget() -> HoverCardAction {
        guard hoveredSessionID != nil else {
            return .none
        }
        hoveredSessionID = nil
        return .dismiss
    }

    /// The countdown that `arm` started has finished. The pointer may have left, or moved to
    /// another row, in the meantime.
    func countdownFinished(for sessionID: String) -> HoverCardAction {
        hoveredSessionID == sessionID ? .present(sessionID: sessionID) : .none
    }

    /// The list has been rebuilt, which happens on every event.
    mutating func sessionsChanged(to liveSessionIDs: some Collection<String>) -> HoverCardAction {
        guard let hoveredSessionID else {
            return .none
        }
        guard liveSessionIDs.contains(hoveredSessionID) else {
            self.hoveredSessionID = nil
            return .dismiss
        }
        return .reattach(sessionID: hoveredSessionID)
    }
}

/// The panel that appears under a hovered row.
///
/// A window of its own rather than `NSView.toolTip`. AppKit's tooltips are built for an
/// application the pointer is already working in: they wait about a second, and they are
/// tied to a window that expects to be key. This widget is hovered while its owner is in the
/// background, and the whole point of the card is to answer a glance.
@MainActor
final class SessionHoverCard {
    /// Long enough not to flash while the pointer crosses the widget on its way elsewhere,
    /// short enough to feel like an answer rather than a wait.
    static let appearanceDelay: TimeInterval = 0.5
    /// How far below the hovered row the card sits. Unscaled, unlike everything else about
    /// the card: it is the distance between two windows, not part of either drawing.
    static let rowGap: CGFloat = 4

    /// The size the card is drawn at, which the widget's own scale decides.
    ///
    /// Settable, and the one place in the widget where a style has to be pushed into a view
    /// rather than handed to a new one: the card is a single panel that outlives every
    /// rebuild of the list — the pointer is resting on a row while the scale changes — so it
    /// takes the new size where a row would simply be built again.
    var style: WidgetStyle = .standard {
        didSet {
            guard style.scale != oldValue.scale else {
                return
            }
            applyStyle()
        }
    }

    private let panel: NSPanel
    private let label: NSTextField
    /// Kept so the padding can follow the scale; a constraint's constant is the only part of
    /// it that can be changed after it is activated.
    private var paddingConstraints: [NSLayoutConstraint] = []
    /// Where the card was placed, so a change of text can be placed again. Resizing without
    /// re-placing broke the two things the placement exists for: a card that grew could run
    /// off the bottom of the screen, or cover the row it describes.
    private var anchorRowFrame: NSRect?

    init() {
        label = NSTextField(labelWithString: "")
        label.font = WidgetStyle.standard.secondaryFont
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let padding = WidgetStyle.standard.hoverCardPadding
        let effect = makeBackdrop(cornerRadius: WidgetStyle.panelCornerRadius)
        effect.addSubview(label)
        paddingConstraints = [
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: padding),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -padding),
        ]
        NSLayoutConstraint.activate(paddingConstraints)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: WidgetStyle.standard.hoverCardMaximumWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Just above the widget it belongs to, and no higher. `.popUpMenu` is above the menu
        // bar: a card sitting there while the status-bar menu is tracking puts a window that
        // ignores mouse events over the menu the pointer is aiming at.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // The same behaviour as the widget. `.transient` was wrong for an accessory
        // application, which is never the active one: it asks the window server to hide the
        // card whenever the app is inactive, which for this app is always.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // The card must never take the pointer. Under it, the row would see the pointer
        // leave, hide the card, see the pointer return, and show it again — a flicker with
        // no way out.
        panel.ignoresMouseEvents = true
    }

    /// Restates the font and the padding, and lays the card out again at the new size.
    ///
    /// The relaying is the point: the panel's size was worked out from the old font, so
    /// without it a card open at the moment of the change keeps its old rectangle around new
    /// text until the pointer leaves the row.
    private func applyStyle() {
        label.font = style.secondaryFont
        let padding = style.hoverCardPadding
        for constraint in paddingConstraints {
            // Trailing and bottom hold the negative of the same gap.
            constraint.constant = constraint.constant < 0 ? -padding : padding
        }
        guard panel.isVisible else {
            return
        }
        // Cleared first, because `place` skips text it is already showing — and the text has
        // not changed here, only the size it has to be measured at.
        let text = label.stringValue
        label.stringValue = ""
        place(text: text)
    }

    var isVisible: Bool { panel.isVisible }

    /// What the card currently reads, for a test that cannot look at the screen.
    var text: String { label.stringValue }

    /// Positioned under the hovered row and nudged back inside the screen it is on. A card
    /// that hangs off the edge is unreadable exactly when a row is at the edge, which for a
    /// widget parked in a corner is most of the time.
    func show(text: String, below rowFrameOnScreen: NSRect) {
        anchorRowFrame = rowFrameOnScreen
        // Cleared so a card shown again for the same session is placed rather than skipped
        // as unchanged: the row it belongs beside may have moved since.
        label.stringValue = ""
        place(text: text)
        panel.orderFrontRegardless()
    }

    func updateText(_ text: String) {
        guard panel.isVisible else {
            return
        }
        place(text: text)
    }

    func hide() {
        anchorRowFrame = nil
        panel.orderOut(nil)
    }

    /// Sizing and placement in one step, always in that order: the origin depends on the
    /// size, so a resize that skipped the placement left the card wherever it happened to
    /// grow from.
    ///
    /// Neither is asked for unless it changes. Resizing and moving a window are requests to
    /// the window server, the card is refreshed on every event while it is open, and the
    /// text that changes most often — the elapsed time — usually changes no dimension at all.
    private func place(text: String) {
        guard let anchorRowFrame, text != label.stringValue else {
            return
        }
        label.stringValue = text
        label.preferredMaxLayoutWidth = style.hoverCardMaximumWidth - 2 * style.hoverCardPadding

        let size = fittingSize()
        guard size != panel.frame.size else {
            return
        }
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(below: anchorRowFrame, size: panel.frame.size))
    }

    /// As wide as its longest line, up to the cap. A card fixed at the cap would stand as a
    /// wide empty rectangle behind two short lines.
    private func fittingSize() -> NSSize {
        let padding = style.hoverCardPadding
        let available = style.hoverCardMaximumWidth - 2 * padding
        let text = label.sizeThatFits(NSSize(width: available, height: .greatestFiniteMagnitude))
        return NSSize(
            width: min(ceil(text.width), available) + 2 * padding,
            height: ceil(text.height) + 2 * padding
        )
    }

    private func origin(below rowFrameOnScreen: NSRect, size: NSSize) -> NSPoint {
        let screen =
            NSScreen.screens.first { $0.frame.intersects(rowFrameOnScreen) } ?? NSScreen.main
        return Self.origin(
            below: rowFrameOnScreen,
            size: size,
            visibleFrame: screen?.visibleFrame
        )
    }

    /// Where the card goes for a row at this place on screen.
    ///
    /// Free of any window, the way `HUDPlacement.origin` is: a card that hangs off the edge
    /// is unreadable exactly when the widget is parked in a corner, which is where a widget
    /// is usually parked, and that is worth checking without a second display to hand.
    static func origin(below rowFrameOnScreen: NSRect, size: NSSize, visibleFrame: NSRect?) -> NSPoint {
        var origin = NSPoint(x: rowFrameOnScreen.minX, y: rowFrameOnScreen.minY - size.height - rowGap)
        guard let visible = visibleFrame else {
            return origin
        }

        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        if origin.y < visible.minY {
            // No room underneath: sit above the row instead of off the bottom of the screen.
            origin.y = rowFrameOnScreen.maxY + rowGap
        }
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return origin
    }
}
