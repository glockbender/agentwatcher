import AgentWatchCore
import AppKit
import SwiftUI

/// The one window where Agent Watch is set up: a sidebar of panes, each a grouped form.
///
/// SwiftUI, because a settings window is what its forms, lists and pickers are made for: a list
/// reordered by dragging, controls that keep their place when an option does not apply, and the
/// look of System Settings without a line of layout arithmetic. The stores stay the single
/// source of truth — every control writes straight to one and the window reads it back.
///
/// The sidebar carries the system's translucent material and the forms sit on the window's own
/// background, as in System Settings. Real Liquid Glass needs the macOS 26 SDK, which this
/// project does not build with yet.
@MainActor
final class WidgetSettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(
        themes: ThemeStore,
        settings: WidgetSettingsStore,
        rowLayouts: RowLayoutStore,
        shortcuts: WidgetShortcutController,
        host: StatusMenuHost,
        version: String?
    ) {
        model = SettingsModel(
            themes: themes,
            settings: settings,
            rowLayouts: rowLayouts,
            shortcuts: shortcuts,
            host: host,
            version: version
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Watch Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.center()
        super.init(window: window)
        window.delegate = self
        shortcuts.onStatusChange = { [weak model] in
            model?.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isShowing: Bool {
        window?.isVisible == true
    }

    /// Opens the window, or brings it forward. Not a toggle: a settings window is closed with its
    /// own close button.
    func present() {
        model.themes.reload()
        model.refresh()
        buildPages()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.isShown = true
    }

    /// Something outside the window changed a setting it shows.
    func refresh() {
        model.refresh()
    }

    /// The pages, unless the window already holds them.
    func buildPages() {
        if !hasPages {
            window?.contentView = NSHostingView(rootView: SettingsView(model: model))
        }
    }

    var hasPages: Bool {
        window?.contentView is NSHostingView<SettingsView>
    }

    /// Lets go of the pages when the window closes, and builds them again when it opens.
    ///
    /// A closed window keeps its views, and these are a whole SwiftUI form with live examples
    /// in it: measured on a copy with 19 sessions, the theme editor held 33 MB after the window
    /// closed, and its examples kept their timers running. Where the window was is the model's,
    /// so the page and the back and forward history survive.
    func windowWillClose(_ notification: Notification) {
        model.isShown = false
        model.stopRecordingShortcut()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard self?.window?.isVisible == false else { return }
                self?.window?.contentView = NSView()
                // And the pages they were in: malloc keeps freed pages for the next allocation,
                // and without this the memory the window used stays counted against the app.
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        model.stopRecordingShortcut()
    }

    #if DEBUG
        /// Draws every pane into `directory` as PNG, then a pane after each scripted change, so
        /// the window can be checked without a person or screen-recording rights: a process may
        /// always draw its own views.
        func snapshot(into directory: URL, then finish: @escaping () -> Void) {
            present()
            window?.setContentSize(NSSize(width: 760, height: 1500))
            window?.setFrameOrigin(NSPoint(x: 40, y: 40))
            var steps: [(String, () -> Void)] = SettingsPage.allCases.map { page in
                (page.rawValue, { self.model.go(page) })
            }
            steps += [
                (
                    "rows-branch-on",
                    {
                        self.model.go(.rows)
                        self.model.setLayout(self.model.layout.changing(parts: self.model.layout.parts + [.branch]))
                    }
                ),
                (
                    "rows-lamp-dragged-to-top",
                    {
                        let listed = RowPartList.listed(for: self.model.layout)
                        let moved = Reorder.moving(RowPart.lamp, onto: listed[0], in: listed)
                        self.model.setLayout(
                            self.model.layout.changing(parts: RowPartList.parts(from: moved, in: self.model.layout)))
                    }
                ),
                (
                    "order-blocks",
                    {
                        self.model.go(.order)
                        self.model.update { self.model.settings.setSessionOrder(.blocks) }
                    }
                ),
                ("back-to-rows", { self.model.goBack() }),
                ("forward-to-order", { self.model.goForward() }),
                (
                    "appearance-light",
                    {
                        self.model.go(.appearance)
                        self.model.update { self.model.themes.select(ThemeMode.light) }
                    }
                ),
            ]
            func run(_ index: Int) {
                guard index < steps.count else {
                    finish()
                    return
                }
                steps[index].1()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.write(directory.appendingPathComponent("\(index)-\(steps[index].0).png"))
                    run(index + 1)
                }
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            run(0)
        }

        private func write(_ url: URL) {
            guard let number = window?.windowNumber, let png = captureWindow(number) else {
                return
            }
            try? png.write(to: url)
        }
    #endif
}

#if DEBUG
    /// A window of this process as PNG, optionally with whatever is on screen below it, through
    /// `CGWindowListCreateImage` — looked up at run time, since it is deprecated and this is a
    /// debug aid, not a feature.
    func captureWindow(_ number: Int, withDesktop: Bool = false, in rect: CGRect = .null) -> Data? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let options: CGWindowListOption =
            withDesktop ? [.optionOnScreenBelowWindow, .optionIncludingWindow] : .optionIncludingWindow
        guard
            let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
            let image = unsafeBitCast(symbol, to: Capture.self)(
                rect, options.rawValue, CGWindowID(number),
                CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
            )?.takeRetainedValue()
        else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
#endif
