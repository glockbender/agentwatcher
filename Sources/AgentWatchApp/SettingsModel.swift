import AgentWatchCore
import AppKit
import SwiftUI

/// What the settings window reads and asks for from the application, beside the stores it
/// writes itself. A protocol for the reason `StatusMenuHost` is one.
@MainActor
protocol SettingsHost: AnyObject {
    var isWidgetVisible: Bool { get }
    var isEventDebugVisible: Bool { get }
    var checksForUpdatesOnLaunch: Bool { get set }
    var isReadingTranscripts: Bool { get }
    var transcriptFaultedSessionCount: Int { get }
    func toggleWidget()
    func showTooling()
    func toggleEventDebug()
    func checkForUpdates()
    func resetWidgetPosition()
    func resetWidgetSize()
    #if AGENT_WATCH_DEBUG_CAPTURE
        /// When the current recording stops, or `nil` when none is running.
        var rawCaptureExpiry: Date? { get }
        var recordedPayloadBytes: Int { get }
        func toggleRawHookCapture()
        func deleteRawHookRecordings()
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
    private weak var host: SettingsHost?

    @Published private(set) var revision = 0
    @Published var isShown = false
    /// A page that shows themes reads their folder again, so a file dropped in or corrected
    /// there is listed, and the editor changes what the file now holds.
    /// Leaving a page also ends a recording of the shortcut started on it.
    @Published private(set) var page: SettingsPage = .widget {
        didSet {
            stopRecordingShortcut()
            if page.parent == .appearance {
                themes.reload()
            }
        }
    }
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
        host: SettingsHost,
        version: String?
    ) {
        self.themes = themes
        self.settings = settings
        self.rowLayouts = rowLayouts
        self.shortcuts = shortcuts
        self.host = host
        self.version = version
        listedParts = RowPartList.listed(for: rowLayouts.layout)
    }

    func refresh() {
        syncListedParts()
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

    /// The Rows page's list: every part in the order a person arranged them, the ones switched
    /// off included. Kept here rather than in the page, so that a part switched on takes the
    /// place it is seen in — the row itself keeps no place for a part it does not show.
    @Published var listedParts: [RowPart] = []

    func reorderParts(_ listed: [RowPart]) {
        listedParts = listed
        setLayout(layout.changing(parts: RowPartList.parts(from: listed, in: layout)))
    }

    func switchPart(_ part: RowPart, on: Bool) {
        setLayout(layout.changing(parts: RowPartList.parts(from: listedParts, in: layout, switching: part, on: on)))
    }

    func countActivity(_ kind: ActivityKind, _ counted: Bool) {
        var kinds = layout.counterKinds
        if counted { kinds.insert(kind) } else { kinds.remove(kind) }
        setLayout(layout.changing(counterKinds: kinds))
    }

    func restoreOrderDefaults() {
        update {
            settings.setSessionOrder(.arrival)
            settings.setSessionBlockOrder(SessionBlock.defaultOrder)
        }
    }

    func restoreRowDefaults() {
        listedParts = RowPartList.listed(for: .standard)
        setLayout(.standard)
    }

    /// The list read again from the row when the two disagree — the row was changed from
    /// somewhere else — and left alone when they agree, which keeps the switched-off parts
    /// where a drag put them.
    private func syncListedParts() {
        if listedParts.isEmpty || RowPartList.parts(from: listedParts, in: layout) != layout.parts {
            listedParts = RowPartList.listed(for: layout)
        }
    }

    var checksForUpdatesOnLaunch: Bool {
        get { host?.checksForUpdatesOnLaunch ?? false }
        set { update { host?.checksForUpdatesOnLaunch = newValue } }
    }

    var transcriptSummary: String {
        transcriptReadingSummary(
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

    var editedLookIsDark: Bool {
        switch themeScope {
        case .both: themes.isDark
        case .light: false
        case .dark: true
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
    ///
    /// A change that changes nothing is not a change: it leaves the built-in theme uncopied,
    /// where the copy would have been put in use and then refused its old name.
    func changeTheme(_ change: (inout WidgetTheme) -> Void) {
        var changed = themes.theme
        change(&changed)
        guard changed != themes.theme else {
            return
        }
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
        attempt { try themes.duplicate(theme) }
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
        if let recorder = shortcutRecorder, recorder.isRecording {
            recorder.stopRecording()
            shortcutRecorded(.cancelled)
        } else if shortcuts.isMuted {
            // The button went with its page and took its recording along; the combination it
            // muted is heard again.
            shortcuts.isMuted = false
            refresh()
        }
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

    var shortcutStatus: String {
        shortcutRefusal ?? shortcutStatusLine(shortcuts.status)
    }
}
