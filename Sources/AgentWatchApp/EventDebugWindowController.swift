import AppKit

@MainActor
final class EventDebugWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

    private var entryLengths: [Int] = []

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
        let entries = initialEntries.suffix(EventDebugLog.maximumEntryCount).map(EventDebugLog.boundedEntry)
        entryLengths = entries.map { ($0 as NSString).length + 1 }
        textView.string = entries.map { $0 + "\n" }.joined()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func append(_ entry: String) {
        let line = EventDebugLog.boundedEntry(entry) + "\n"
        entryLengths.append((line as NSString).length)
        textView.textStorage?.append(NSAttributedString(string: line))
        if entryLengths.count > EventDebugLog.maximumEntryCount {
            let removedLength = entryLengths.removeFirst()
            textView.textStorage?.deleteCharacters(in: NSRange(location: 0, length: removedLength))
        }
        if isVisible { textView.scrollToEndOfDocument(nil) }
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
            // A hidden window is not scrolled as entries arrive, so it opens where it was left;
            // the newest entries are what a person opens it to read.
            textView.scrollToEndOfDocument(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
