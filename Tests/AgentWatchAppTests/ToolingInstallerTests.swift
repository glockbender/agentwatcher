import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// Real files in a real directory. The whole point of this type is what it leaves on disk for
/// another program to find, so a test that stubbed the file system would check only the part
/// that was never in doubt.
@MainActor
final class ToolingInstallerTests: XCTestCase {
    func testInstallingLeavesAPluginClaudeCodeWouldLoadAndReadsBackAsInstalled() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let installer = ToolingInstaller(home: home)

        try installer.installHooks(for: .claude, senderPath: sender.path, hooks: ToolingHooks.hooks(for: .claude))

        // The manifest is what makes the folder a plugin rather than a bare skill.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude/skills/agent-watch/.claude-plugin/plugin.json").path
            )
        )
        XCTAssertEqual(installer.hookState(for: .claude, delivery: .arrived), .installed)
    }

    func testRemovingTakesThePluginAwayEntirely() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let installer = ToolingInstaller(home: home)
        try installer.installHooks(for: .claude, senderPath: sender.path, hooks: ToolingHooks.hooks(for: .claude))

        try installer.removeHooks(for: .claude)

        XCTAssertEqual(installer.hookState(for: .claude, delivery: .arrived), .absent)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude/skills/agent-watch").path
            ),
            "an uninstall that leaves the folder leaves a plugin Claude Code still loads"
        )
    }

    /// Removal deletes a folder, so it has to be sure the folder is ours. A person may have a
    /// skill of their own under this name; taking it away would be destroying their work.
    func testAFolderOfTheSameNameThatIsNotOursIsLeftAlone() throws {
        let home = try makeHome()
        let theirs = home.appendingPathComponent(".claude/skills/agent-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("their own skill".utf8).write(to: theirs.appendingPathComponent("SKILL.md"))

        XCTAssertThrowsError(try ToolingInstaller(home: home).removeHooks(for: .claude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.appendingPathComponent("SKILL.md").path))
    }

    /// Codex keeps its hooks in a file of its own that may hold somebody else's too, so this
    /// is a merge rather than a folder we own — and the file gets saved before it is edited,
    /// for the same reason the settings file does.
    func testCodexHooksAreInstalledIntoItsOwnFileAndTakenBackOutOfIt() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let hooksURL = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say bye"}]}]}}"#.utf8)
            .write(to: hooksURL)
        let installer = ToolingInstaller(home: home)

        try installer.installHooks(for: .codex, senderPath: sender.path, hooks: ToolingHooks.hooks(for: .codex))
        XCTAssertEqual(installer.hookState(for: .codex, delivery: .arrived), .installed)

        try installer.removeHooks(for: .codex)
        XCTAssertEqual(installer.hookState(for: .codex, delivery: .arrived), .absent)
        XCTAssertTrue(
            String(data: try Data(contentsOf: hooksURL), encoding: .utf8)?.contains("say bye") == true,
            "somebody else's hook must survive both operations"
        )
        // Two changes, so two copies: the promise is a copy before each change, not one copy
        // per file ever. A timestamp collision inside the same second is what the suffix in
        // `backUp` is for, and this is where that would show.
        XCTAssertEqual(try Self.backups(of: hooksURL).count, 2, "each change saves the file first")
    }

    /// Every copy `backUp` makes of one file, by the name it gives them.
    private static func backups(of url: URL) throws -> [String] {
        let name = url.lastPathComponent
        return try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("\(name).agentwatch-backup") }
    }

    /// The mirror of the removal guard, and the reason it matters: installing into somebody
    /// else's folder would make it look like ours, and then removal — which trusts the
    /// manifest — would delete their work.
    func testInstallingIntoAFolderThatIsNotOursIsRefused() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let theirs = home.appendingPathComponent(".claude/skills/agent-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("their own skill".utf8).write(to: theirs.appendingPathComponent("SKILL.md"))
        let installer = ToolingInstaller(home: home)

        XCTAssertThrowsError(
            try installer.installHooks(for: .claude, senderPath: sender.path, hooks: ToolingHooks.hooks(for: .claude))
        )
        XCTAssertEqual(
            try String(contentsOf: theirs.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "their own skill"
        )
        XCTAssertEqual(installer.hookState(for: .claude, delivery: .arrived), .absent)
    }

    /// Codex's hooks are merged in beside somebody else's. A merge into a file
    /// we could not read is a replacement wearing a merge's name.
    func testAnUnreadableCodexHooksFileStopsTheMergeInsteadOfReplacingIt() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let hooksURL = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let theirs = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say bye"#
        try Data(theirs.utf8).write(to: hooksURL)
        let installer = ToolingInstaller(home: home)

        XCTAssertThrowsError(
            try installer.installHooks(for: .codex, senderPath: sender.path, hooks: ToolingHooks.hooks(for: .codex))
        )
        XCTAssertEqual(try String(contentsOf: hooksURL, encoding: .utf8), theirs)
    }

    /// A configuration the app cannot read is not an absent one, and the menu must not offer
    /// to install over it: the offer would be a promise to repair something whose contents
    /// are unknown.
    func testAConfigurationThatCannotBeReadIsReportedAsSuchRatherThanAsAbsent() throws {
        let home = try makeHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let codexURL = home.appendingPathComponent(".codex/hooks.json")
        let pluginURL = home.appendingPathComponent(".claude/skills/agent-watch/hooks/hooks.json")
        for url in [settingsURL, codexURL, pluginURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{ not json".utf8).write(to: url)
        }
        let installer = ToolingInstaller(home: home)

        XCTAssertEqual(installer.hookState(for: .claude, delivery: .arrived), .unreadable)
        XCTAssertEqual(installer.hookState(for: .codex, delivery: .arrived), .unreadable)
        XCTAssertFalse(
            ToolingInstallationState.unreadable.wantsInstalling,
            "pressing the line must not write over a file whose contents nobody knows"
        )
    }

    // MARK: - Helpers

    /// An agent started with its variable reads hooks from that folder only — measured on
    /// Codex 0.153.4 and 0.161.0 and Claude Code 2.1.294 — so that is where they go, in the
    /// same shape as in the default folder, and the default folder is left as it was.
    func testHooksGoIntoTheFolderTheyAreInstalledInAndNowhereElse() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let installer = ToolingInstaller(home: home)
        let codexWork = home.appendingPathComponent(".codex-work", isDirectory: true)
        let claudeWork = home.appendingPathComponent(".claude-work", isDirectory: true)

        for (source, folder) in [(AgentSource.codex, codexWork), (.claude, claudeWork)] {
            try installer.installHooks(
                for: source, in: folder, senderPath: sender.path, hooks: ToolingHooks.hooks(for: source))

            XCTAssertEqual(installer.hookState(for: source, in: folder, delivery: .arrived), .installed)
            XCTAssertEqual(installer.hookState(for: source, delivery: .arrived), .absent, "\(source)'s default folder")
        }
        XCTAssertEqual(installer.hooksPath(for: .codex, in: codexWork).path, codexWork.path + "/hooks.json")
        XCTAssertEqual(
            installer.hooksPath(for: .claude, in: claudeWork).path,
            claudeWork.path + "/skills/agent-watch/hooks/hooks.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))

        try installer.removeHooks(for: .claude, in: claudeWork)
        XCTAssertEqual(installer.hookState(for: .claude, in: claudeWork, delivery: .arrived), .absent)
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchToolingTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSender(in home: URL) throws -> URL {
        let url = home.appendingPathComponent("AgentWatchSend")
        try Data().write(to: url)
        return url
    }
}
