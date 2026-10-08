import AgentWatchCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

/// Draws settings pages into PNG files, for a person to look at: the ones that show a theme,
/// the two whose switches say beside them why one is greyed, and `General`.
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
        let host = FakeAppHost()
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
        try draw(AnyView(RowPane(model: model)), height: 900, named: "settings-rows", in: directory)
        try draw(AnyView(MenuBarPane(model: model)), height: 820, named: "settings-menu-bar", in: directory)
        try draw(AnyView(GeneralPane(model: model)), height: 900, named: "settings-general", in: directory)
        _ = host
    }

    /// The Tooling page with one of each interesting state on screen at once: an agent that is
    /// installed and delivering, one whose records have never fired, a status line somebody
    /// else's command already holds, and three IDEs that stand in three different places. Then
    /// the same page with the IDE section reading this machine — the one part no fixture can
    /// check: whether the search finds the IDEs a person has, and whether the plugin's reply is
    /// read back. Drawn at the window's default width and at its narrowest.
    func testDrawTheToolingPage() throws {
        let requested = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"]
        try XCTSkipIf(requested == nil, "a drawing probe, not a check: set SETTINGS_RENDER_DIR")
        let directory = try XCTUnwrap(requested)

        let fixture = ToolingModel(
            facts: { [idePlugins] in
                ToolingFacts(
                    hookState: { $0 == .claude ? .installed : .unheard },
                    statusLineState: .theirs(command: "~/bin/my-status-line.sh"),
                    hooksPath: {
                        switch $0 {
                        case .claude: "/Users/someone/.claude/skills/agent-watch/hooks.json"
                        case .codex: "/Users/someone/.codex/hooks.json"
                        }
                    },
                    statusLinePath: "/Users/someone/.claude/settings.json",
                    senderPath: "/Users/someone/Library/Application Support/AgentWatch/AgentWatchSend",
                    senderIsTiedToThisBuild: true,
                    idePlugins: idePlugins(),
                    stagedPlugin: StagedIDEPlugin(fileName: "agent-watch-ide-0.1.3.zip", version: "0.1.3"),
                    idePluginDirectoryPath: "/Users/someone/Library/Application Support/AgentWatch/ide-plugin",
                    agentPaths: [.claude: "/Users/someone/.local/bin/claude"],
                    lastError: "Could not change the integration: the file is locked"
                )
            },
            act: { _ in }
        )
        try draw(AnyView(ToolingPane(tooling: fixture)), height: 1700, named: "settings-tooling", in: directory)
        // The settings window's narrowest: 680 points less a 170-point sidebar.
        try draw(
            AnyView(ToolingPane(tooling: fixture)), height: 1900, width: 510, named: "settings-tooling-narrow",
            in: directory)

        let staged = IDEPluginFiles.staged()
        let isDaemonInstalled = JetBrainsInstallation.isDaemonInstalled()
        let readings = JetBrainsIDEs.installed().map { ide in
            IDEPluginReading(
                ide: ide,
                presence: IDEPluginInstallation.presence(
                    productScheme: ide.productScheme,
                    isDaemonInstalled: isDaemonInstalled,
                    reply: IDEPluginFiles.reply(forDataDirectoryName: ide.product.dataDirectoryName),
                    check: .notAsked
                )
            )
        }
        let here = ToolingModel(
            facts: {
                ToolingFacts(
                    hookState: { _ in .installed },
                    statusLineState: .connected,
                    hooksPath: { _ in "—" },
                    statusLinePath: "—",
                    senderPath: "—",
                    senderIsTiedToThisBuild: false,
                    idePlugins: readings,
                    stagedPlugin: staged?.plugin,
                    idePluginDirectoryPath: IDEPluginFiles.pluginDirectory()?.path ?? ""
                )
            },
            act: { _ in }
        )
        try draw(AnyView(ToolingPane(tooling: here)), height: 1700, named: "settings-tooling-here", in: directory)
    }

    /// Three IDEs standing in the three places that read differently: one running with an
    /// older plugin in it, one running that has never answered, and one that is not running
    /// at all and so cannot be asked anything.
    private func idePlugins() -> [IDEPluginReading] {
        [
            IDEPluginReading(
                ide: ide("GoLand", version: "2026.1.4", directory: "GoLand2026.1", scheme: "goland", running: true),
                presence: .answeredEarlier(
                    IDEPluginReply(
                        token: "kh2l0bfzomrpl7o4",
                        pluginVersion: "0.1.2",
                        ideBuild: "GO-261.26222.72",
                        answeredAt: Date(timeIntervalSince1970: 100_000)
                    )
                )
            ),
            IDEPluginReading(
                ide: ide("PyCharm", version: "2026.1.4", directory: "PyCharm2026.1", scheme: "pycharm", running: true),
                presence: .neverAnswered
            ),
            IDEPluginReading(
                ide: ide(
                    "IntelliJ IDEA",
                    version: "2026.1.1",
                    directory: "IntelliJIdea2026.1",
                    scheme: "idea",
                    running: false
                ),
                presence: .neverAnswered
            ),
        ]
    }

    private func ide(
        _ name: String,
        version: String,
        directory: String,
        scheme: String,
        running: Bool
    ) -> InstalledJetBrainsIDE {
        InstalledJetBrainsIDE(
            product: JetBrainsProduct(name: name, version: version, dataDirectoryName: directory),
            bundlePath: "/Users/someone/Applications/\(name).app",
            productScheme: scheme,
            isRunning: running
        )
    }

    /// 570 points: the settings window opens 760 wide, and its sidebar takes about 190 of them.
    private func draw(
        _ root: AnyView, height: CGFloat, width: CGFloat = 570, named name: String, in directory: String
    ) throws {
        let size = NSSize(width: width, height: height)
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
