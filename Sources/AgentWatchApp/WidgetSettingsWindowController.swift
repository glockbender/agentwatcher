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

/// What the panes read and write: the stores themselves, and one counter that tells SwiftUI a
/// store has changed. The stores are not observable, so every write goes through `update`.
@MainActor
final class SettingsModel: ObservableObject {
    let themes: ThemeStore
    let settings: WidgetSettingsStore
    let rowLayouts: RowLayoutStore
    let shortcuts: WidgetShortcutController
    let version: String?
    private weak var host: StatusMenuHost?

    @Published private(set) var revision = 0
    @Published var isShown = false
    @Published private(set) var page: SettingsPage = .widget
    private var back: [SettingsPage] = []
    private var forward: [SettingsPage] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Where the window goes next, remembered as System Settings does: back and forward walk
    /// the pages in the order they were opened.
    func go(_ page: SettingsPage) {
        guard page != self.page else { return }
        back.append(self.page)
        forward.removeAll()
        self.page = page
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(page)
        page = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(page)
        page = next
    }
    /// What the last key press was refused for, shown in place of the status until something
    /// else happens.
    @Published var shortcutRefusal: String?
    weak var shortcutRecorder: ShortcutRecorderButton?

    init(
        themes: ThemeStore,
        settings: WidgetSettingsStore,
        rowLayouts: RowLayoutStore,
        shortcuts: WidgetShortcutController,
        host: StatusMenuHost,
        version: String?
    ) {
        self.themes = themes
        self.settings = settings
        self.rowLayouts = rowLayouts
        self.shortcuts = shortcuts
        self.host = host
        self.version = version
    }

    func refresh() {
        revision += 1
    }

    func update(_ write: () -> Void) {
        write()
        refresh()
    }

    var layout: RowLayout {
        rowLayouts.layout
    }

    func setLayout(_ layout: RowLayout) {
        update { rowLayouts.setLayout(layout) }
    }

    var checksForUpdatesOnLaunch: Bool {
        get { host?.checksForUpdatesOnLaunch ?? false }
        set { update { host?.checksForUpdatesOnLaunch = newValue } }
    }

    var transcriptSummary: String {
        transcriptMenuSummary(
            interval: settings.transcriptPollInterval,
            isReading: host?.isReadingTranscripts ?? false,
            faultedSessionCount: host?.transcriptFaultedSessionCount ?? 0
        )
    }

    func checkForUpdates() {
        host?.checkForUpdates()
    }

    func resetWidgetPosition() {
        host?.resetWidgetPosition()
    }

    func resetWidgetSize() {
        host?.resetWidgetSize()
    }

    var isWidgetVisible: Bool {
        get { host?.isWidgetVisible ?? false }
        set {
            guard newValue != isWidgetVisible else { return }
            update { host?.toggleWidget() }
        }
    }

    // MARK: - The theme

    /// Which of the theme's two looks an edit goes into. Both by default: an edit made to the
    /// look on screen alone would leave the other one as it was, and the change would seem to
    /// undo itself the next time the Mac switches between light and dark.
    enum ThemeScope: String, CaseIterable {
        case both, light, dark

        var name: String {
            switch self {
            case .both: "Light and Dark"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    @Published var themeScope: ThemeScope = .both
    /// What the last change to a theme was refused for, shown until the next one succeeds.
    @Published private(set) var themeProblem: String?

    /// The look the editor shows: the one it writes into, or the one on screen when it writes
    /// into both.
    var editedLook: WidgetTheme.Look {
        switch themeScope {
        case .both: themes.look
        case .light: themes.theme.light
        case .dark: themes.theme.dark
        }
    }

    /// Changes the theme in use — a copy of it first, when it is the built-in one.
    func editTheme(_ change: (inout WidgetTheme.Look) -> Void) {
        changeTheme { theme in
            switch themeScope {
            case .both:
                change(&theme.light)
                change(&theme.dark)
            case .light:
                change(&theme.light)
            case .dark:
                change(&theme.dark)
            }
        }
    }

    /// Changes something about the theme in use that is not one of its looks: its name.
    func changeTheme(_ change: (inout WidgetTheme) -> Void) {
        do {
            var theme = try themes.editable()
            let name = theme.name
            change(&theme)
            try themes.save(theme, replacing: name)
            themeProblem = nil
        } catch {
            themeProblem = error.localizedDescription
        }
        refresh()
    }

    /// Puts a theme in use and opens it in the editor: the editor changes the theme on screen,
    /// so what it shows is what the widget does.
    func edit(_ theme: WidgetTheme) {
        update { themes.select(theme) }
        go(.theme)
    }

    func duplicate(_ theme: WidgetTheme) {
        attempt { try themes.create(from: theme, named: "\(theme.name) copy") }
    }

    /// A theme of the built-in colours, in use and open in the editor.
    func newTheme() {
        if attempt({ try themes.create() }) {
            go(.theme)
        }
    }

    func delete(_ theme: WidgetTheme) {
        attempt { try themes.delete(theme) }
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a theme file to add to Agent Watch."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        attempt { try themes.importTheme(from: url) }
    }

    func export(_ theme: WidgetTheme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        attempt { try themes.export(theme, to: url) }
    }

    var themeFolderNote: String {
        "Themes are JSON files in the Themes folder, so they can also be shared and edited by hand."
    }

    /// Runs a change to the themes, and keeps what it was refused for to show.
    @discardableResult
    private func attempt(_ change: () throws -> Void) -> Bool {
        defer { refresh() }
        do {
            try change()
            themeProblem = nil
            return true
        } catch {
            themeProblem = error.localizedDescription
            return false
        }
    }

    func showThemeFolder() {
        guard let folder = themes.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func showTooling() {
        host?.showTooling()
    }

    var isEventLogVisible: Bool {
        host?.isEventDebugVisible ?? false
    }

    func toggleEventLog() {
        update { host?.toggleEventDebug() }
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        var rawCaptureExpiry: Date? {
            host?.rawCaptureExpiry
        }

        var recordedPayloadBytes: Int {
            host?.recordedPayloadBytes ?? 0
        }

        func toggleRawHookCapture() {
            update { host?.toggleRawHookCapture() }
        }

        func deleteRawHookRecordings() {
            update { host?.deleteRawHookRecordings() }
        }
    #endif

    // MARK: - The shortcut

    func startRecordingShortcut() {
        guard let recorder = shortcutRecorder else {
            return
        }
        shortcutRefusal = nil
        recorder.startRecording()
        // The old combination is still registered while the new one is chosen, and pressing it
        // here would hide the widget out from under the person choosing.
        shortcuts.isMuted = true
        refresh()
    }

    func stopRecordingShortcut() {
        guard let recorder = shortcutRecorder, recorder.isRecording else {
            return
        }
        recorder.stopRecording()
        shortcutRecorded(.cancelled)
    }

    func clearShortcut() {
        shortcutRefusal = nil
        shortcutRecorder?.stopRecording()
        shortcuts.isMuted = false
        update { settings.setToggleShortcut(nil) }
    }

    func shortcutRecorded(_ recording: ShortcutRecording) {
        switch recording {
        case let .recorded(shortcut):
            shortcutRefusal = nil
            settings.setToggleShortcut(shortcut)
        case .cleared:
            shortcutRefusal = nil
            settings.setToggleShortcut(nil)
        case .cancelled:
            shortcutRefusal = nil
        case .refused:
            shortcutRefusal = shortcutAcceptedKeys
        }
        shortcuts.isMuted = shortcutRecorder?.isRecording ?? false
        refresh()
    }

    var isRecordingShortcut: Bool {
        shortcutRecorder?.isRecording ?? false
    }

    var shortcutStatus: String {
        shortcutRefusal ?? shortcutStatusLine(shortcuts.status)
    }
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
