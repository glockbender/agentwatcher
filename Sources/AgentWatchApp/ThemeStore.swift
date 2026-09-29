import AgentWatchCore
import AppKit

/// Which theme is in use, in which mode, and the themes on offer: the built-in one and every
/// file in the `Themes` folder.
///
/// The built-in theme is never written: it lives in the code, so an update can improve it. A
/// person who changes it gets a copy of their own first (`editable`).
final class ThemeStore: PreferenceDefaults {
    private enum Key {
        static let theme = "theme"
        static let mode = "themeMode"
    }

    enum Problem: Error, LocalizedError, Equatable {
        case noFolder
        case unreadable(String)
        case nameTaken(String)
        case emptyName
        case builtIn

        var errorDescription: String? {
            switch self {
            case .noFolder: "There is no folder to keep themes in."
            case let .unreadable(reason): "Not a theme: \(reason)"
            case let .nameTaken(name): "A theme called “\(name)” already exists."
            case .emptyName: "A theme needs a name."
            case .builtIn: "The built-in theme cannot be changed; edit a copy of it."
            }
        }
    }

    private let preferences: PreferenceFile
    let folder: URL?
    /// Where a deleted theme goes. The Trash, so a delete can be undone from the Finder;
    /// a test hands in something that leaves the person's Trash alone.
    private let discard: (URL) throws -> Void
    var onChange: ((WidgetSetting) -> Void)?
    /// The files that could not be read, by name, with what was wrong.
    private(set) var problems: [String] = []
    private(set) var themes: [WidgetTheme] = [.standard]
    /// Each custom theme's file, by theme name: the name inside a file is what counts, and
    /// the file may be called anything.
    private var files: [String: URL] = [:]

    init(
        preferences: PreferenceFile, folder: URL?,
        discard: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.preferences = preferences
        self.folder = folder
        self.discard = discard
        reload()
    }

    var defaultValues: [String: JSONValue] {
        [Key.theme: .string(WidgetTheme.standard.name), Key.mode: .string(ThemeMode.auto.rawValue)]
    }

    var theme: WidgetTheme {
        let name = preferences.string(forKey: Key.theme)
        return themes.first { $0.name == name } ?? .standard
    }

    /// Every theme but the built-in one: the ones a person can edit, rename and delete.
    var customThemes: [WidgetTheme] {
        themes.filter { !isBuiltIn($0) }
    }

    func isBuiltIn(_ theme: WidgetTheme) -> Bool {
        theme.name == WidgetTheme.standard.name && files[theme.name] == nil
    }

    var mode: ThemeMode {
        preferences.string(forKey: Key.mode).flatMap(ThemeMode.init(rawValue:)) ?? .auto
    }

    @MainActor var isDark: Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .auto: NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    @MainActor var look: WidgetTheme.Look {
        theme.look(dark: isDark)
    }

    func select(_ theme: WidgetTheme) {
        preferences.set(theme.name, forKey: Key.theme)
        onChange?(.theme)
    }

    func select(_ mode: ThemeMode) {
        preferences.set(mode.rawValue, forKey: Key.mode)
        onChange?(.theme)
    }

    /// Reads the folder again: a theme dropped in, edited or removed is picked up.
    func reload() {
        problems = []
        files = [:]
        var found: [WidgetTheme] = [.standard]
        let listed = folder.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        for file in (listed ?? []).filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            do {
                var theme = try Self.decode(Data(contentsOf: file))
                theme.name = Self.unique(theme.name, among: Set(found.map(\.name)))
                found.append(theme)
                files[theme.name] = file
            } catch {
                problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        themes = found
    }

    // MARK: - Making and changing themes

    /// The theme in use, ready to be changed: itself when it is a file, a copy of it — in use
    /// from now on — when it is the built-in one.
    func editable() throws -> WidgetTheme {
        let current = theme
        guard isBuiltIn(current) else {
            return current
        }
        return try create(from: current, named: "\(current.name) copy")
    }

    /// A new theme with these colours, under a name nobody has taken, in use at once.
    @discardableResult
    func create(from source: WidgetTheme = .standard, named name: String = "New Theme") throws -> WidgetTheme {
        let copy = try add(source, named: name)
        select(copy)
        return copy
    }

    private func add(_ source: WidgetTheme, named name: String) throws -> WidgetTheme {
        var copy = source
        copy.name = Self.unique(name, among: Set(themes.map(\.name)))
        try write(copy, replacing: nil)
        return copy
    }

    /// A copy of the theme in use, as a file of its own, selected.
    @discardableResult
    func duplicate() -> URL? {
        guard let copy = try? create(from: theme, named: "\(theme.name) copy") else {
            return nil
        }
        return files[copy.name]
    }

    /// Writes a changed theme over the one it was, which may have had another name. Nothing is
    /// written when nothing changed: a colour well reports every shade the pointer passes, and
    /// each write rebuilds every row in the widget.
    func save(_ theme: WidgetTheme, replacing previousName: String) throws {
        guard let previous = themes.first(where: { $0.name == previousName }), !isBuiltIn(previous) else {
            throw Problem.builtIn
        }
        guard theme != previous else {
            return
        }
        let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Problem.emptyName
        }
        guard name == previousName || !themes.contains(where: { $0.name == name }) else {
            throw Problem.nameTaken(name)
        }
        var saved = theme
        saved.name = name
        let wasInUse = self.theme.name == previousName
        try write(saved, replacing: previousName)
        // The widget follows the theme in use, and only that one.
        if wasInUse {
            preferences.set(name, forKey: Key.theme)
            onChange?(.theme)
        }
    }

    /// Moves a theme's file to the Trash. The built-in theme takes over where it was in use.
    func delete(_ theme: WidgetTheme) throws {
        guard !isBuiltIn(theme), let file = files[theme.name] else {
            throw Problem.builtIn
        }
        let wasInUse = self.theme.name == theme.name
        try discard(file)
        files[theme.name] = nil
        themes.removeAll { $0.name == theme.name }
        if wasInUse {
            select(.standard)
        }
    }

    /// Copies a theme file from anywhere into the folder, under a name of its own, and puts it
    /// in use. Read by the same rules as the folder, so what imports is what would load.
    @discardableResult
    func importTheme(from url: URL) throws -> WidgetTheme {
        let theme: WidgetTheme
        do {
            theme = try Self.decode(Data(contentsOf: url))
        } catch {
            throw Problem.unreadable(error.localizedDescription)
        }
        return try create(from: theme, named: theme.name)
    }

    /// The theme as a file somebody else can import.
    func export(_ theme: WidgetTheme, to url: URL) throws {
        try Self.encode(theme).write(to: url, options: .atomic)
    }

    // MARK: - Carried over from before themes

    /// Before the first theme is chosen, whatever colours were set by hand become a theme of
    /// their own, in use, so nobody's widget changes colour on update. The panel's material and
    /// opacity, which were settings of their own before they joined the theme, go into the
    /// theme in use the same way — once: the caller forgets the old keys afterwards.
    ///
    /// Says nothing to `onChange`: this runs at launch, before anything is on screen, and
    /// what is told about a change builds the widget to show it.
    func adoptIfNeeded(
        lampScheme: LampScheme, background: WidgetBackground, material: WidgetMaterial? = nil,
        opacity: CGFloat? = nil
    ) {
        let standard = WidgetTheme.standard.dark
        guard preferences.string(forKey: Key.theme) == nil else {
            adoptSurface(material: material, opacity: opacity)
            return
        }
        let lamps = WidgetTheme.lamps(from: lampScheme)
        let hex = background.color.srgbHex ?? standard.background
        var look = WidgetTheme.Look(background: hex, lamps: lamps)
        look.widgetMaterial = material ?? standard.widgetMaterial
        look.widgetOpacity = opacity ?? standard.widgetOpacity
        guard look != standard else {
            return
        }
        let mine = WidgetTheme(name: "My Theme", light: look, dark: look)
        guard let added = try? add(mine, named: mine.name) else {
            return
        }
        preferences.replace([Key.theme: .string(added.name), Key.mode: .string(ThemeMode.auto.rawValue)])
    }

    private func adoptSurface(material: WidgetMaterial?, opacity: CGFloat?) {
        guard material != nil || opacity != nil else {
            return
        }
        var theme = self.theme
        for isDark in [false, true] {
            var look = theme.look(dark: isDark)
            if let material {
                look.widgetMaterial = material
            }
            if let opacity {
                look.widgetOpacity = opacity
            }
            if isDark { theme.dark = look } else { theme.light = look }
        }
        guard theme != self.theme else {
            return
        }
        if isBuiltIn(self.theme) {
            guard let added = try? add(theme, named: "My Theme") else {
                return
            }
            preferences.set(added.name, forKey: Key.theme)
        } else {
            try? write(theme, replacing: theme.name)
        }
    }

    // MARK: - Files

    private func write(_ theme: WidgetTheme, replacing previousName: String?) throws {
        guard let folder else {
            throw Problem.noFolder
        }
        let old = previousName.flatMap { files[$0] }
        let url =
            old.flatMap { $0.deletingPathExtension().lastPathComponent == Self.fileName(for: theme.name) ? $0 : nil }
            ?? availableFile(for: theme.name, in: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encode(theme).write(to: url, options: .atomic)
        // A rename leaves the old file behind unless it goes; it is the same theme, so it goes
        // for good rather than to the Trash.
        if let old, old != url {
            try? FileManager.default.removeItem(at: old)
        }
        if let previousName, previousName != theme.name {
            files[previousName] = nil
        }
        files[theme.name] = url
        if let previousName, let index = themes.firstIndex(where: { $0.name == previousName }) {
            themes[index] = theme
        } else {
            themes.append(theme)
        }
    }

    private func availableFile(for name: String, in folder: URL) -> URL {
        let base = Self.fileName(for: name)
        var candidate = folder.appendingPathComponent("\(base).json")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).json")
            number += 1
        }
        return candidate
    }

    /// A name as a file can carry it: the two characters a Mac path cannot hold are replaced.
    private static func fileName(for name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// `name`, or `name 2`, `name 3` and on — whichever is free. The built-in theme's name is
    /// never free, so a file that claims it is read as `Default (file)`.
    static func unique(_ name: String, among taken: Set<String>) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.isEmpty ? "Untitled Theme" : trimmed
        if base == WidgetTheme.standard.name {
            base += " (file)"
        }
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    static func decode(_ data: Data) throws -> WidgetTheme {
        try JSONDecoder().decode(WidgetTheme.self, from: data)
    }

    static func encode(_ theme: WidgetTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(theme)
    }
}
