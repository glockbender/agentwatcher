import AgentWatchCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

/// Draws the settings pages that show a theme into PNG files, for a person to look at.
///
/// Skipped unless `SETTINGS_RENDER_DIR` names a directory. Drawn in a window that is never
/// shown, so nothing appears on screen and nothing takes the focus from whoever is working.
///
///     SETTINGS_RENDER_DIR=/tmp/render swift test --filter SettingsRenderProbe
@MainActor
final class SettingsRenderProbe: XCTestCase {
    func testDrawTheThemePages() throws {
        let requested = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"]
        try XCTSkipIf(requested == nil, "a drawing probe, not a check: set SETTINGS_RENDER_DIR")
        let directory = try XCTUnwrap(requested)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchThemes.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let host = FakeStatusMenuHost()
        let themes = ThemeStore(preferences: preferences, folder: folder) { try FileManager.default.removeItem(at: $0) }
        let model = SettingsModel(
            themes: themes, settings: settings, rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)

        try draw(AnyView(AppearancePane(model: model)), height: 700, named: "settings-appearance", in: directory)
        try draw(AnyView(ThemeEditorPane(model: model)), height: 2600, named: "settings-theme", in: directory)
        // The first change: the built-in theme is copied, and everything follows the lamps.
        model.editTheme { look in
            look.setFollowsLamps(true)
            look.menuMotion = .lamp
            look.setMarkMotion(.gradient, fadeTo: NSColor(sRGB: "#FFFB00"), cycle: 2, for: .needsPerson)
        }
        try draw(AnyView(ThemeEditorPane(model: model)), height: 2600, named: "settings-theme-lamps", in: directory)
        try themes.create(named: "Mine")
        try themes.create(named: "Shared with me")
        try draw(AnyView(ThemesPane(model: model)), height: 400, named: "settings-themes", in: directory)
        _ = host
    }

    private func draw(_ root: AnyView, height: CGFloat, named name: String, in directory: String) throws {
        let size = NSSize(width: 620, height: height)
        let hosting = NSHostingView(rootView: root.formStyle(.grouped))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI fills a form in over a few turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("drew \(url.path)")
    }
}
