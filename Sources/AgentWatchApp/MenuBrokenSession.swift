import AppKit

/// The widget's question, standing where the menu's session lines were.
///
/// A menu draws its own lines, and nothing can be drawn over them; what it can hold is a line
/// with a view of any size. So the lines give way to this one, the rest of the menu stays, and
/// the question is the same view the widget shows, darkened backdrop and all.
///
/// Its buttons take no click of their own: whether a button inside a menu's line can track a
/// press has not been measured, and this line's own release is what a menu is known to
/// deliver — seen again with real clicks on this question, measured on macOS 15.3.1. The
/// release is handed to the button it lands on.
@MainActor
final class MenuEndAgentQuestionView: NSView {
    let dialog: EndAgentDialog
    private var pressed: EndAgentDialogButton?

    static let width: CGFloat = 300

    init(
        sessionID: String, sessionName: String?, reason: EndAgentReason = .closedTerminal,
        onCancel: @escaping () -> Void, onEnd: @escaping () -> Void
    ) {
        dialog = EndAgentDialog(
            sessionID: sessionID, sessionName: sessionName, reason: reason, style: .standard, onCancel: onCancel,
            onEnd: onEnd)
        let height = dialog.heightShowingEverything(atWidth: Self.width)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        autoresizingMask = [.width]
        dialog.frame = bounds
        dialog.autoresizingMask = [.width, .height]
        addSubview(dialog)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressed = button(at: event)
        pressed?.isHighlighted = true
    }

    /// A press that started on one button and ended on the other chooses neither. The press
    /// may not arrive at all — only the release was measured — and then the release decides.
    override func mouseUp(with event: NSEvent) {
        let released = button(at: event)
        pressed?.isHighlighted = false
        defer { pressed = nil }
        guard let released, pressed == nil || pressed === released else {
            return
        }
        released.performClick(nil)
    }

    private func button(at event: NSEvent) -> EndAgentDialogButton? {
        let point = dialog.convert(event.locationInWindow, from: nil)
        return [dialog.cancelButton, dialog.endButton].first { button in
            button.convert(button.bounds, to: dialog).contains(point)
        }
    }
}
