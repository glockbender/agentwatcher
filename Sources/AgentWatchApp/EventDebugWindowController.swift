import AppKit

@MainActor
final class EventDebugWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

    init(initialEntries: [String] = []) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Watch Event Debug"
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        window.contentView = scrollView

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 480,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = initialEntries.joined(separator: "\n")
        if !initialEntries.isEmpty {
            textView.string.append("\n")
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func append(_ entry: String) {
        textView.textStorage?.append(NSAttributedString(string: "\(entry)\n"))
        textView.scrollToEndOfDocument(nil)
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func toggle() {
        guard let window else {
            return
        }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
