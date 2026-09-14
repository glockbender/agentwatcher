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

    /// Connecting the status line must be reversible down to the character, because what it
    /// touches is a command a person wrote and Claude Code allows only one of.
    func testConnectingTheStatusLineKeepsTheirCommandAndDisconnectingGivesItBack() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original =
            #"{"statusLine":{"type":"command","command":"bash ~/mine.sh","padding":2,"refreshInterval":5,"hideVimModeIndicator":true,"futureOption":{"enabled":true}},"model":"opus"}"#
        try Data(original.utf8)
            .write(to: settingsURL)
        let installer = ToolingInstaller(home: home)
        XCTAssertEqual(installer.statusLineState(), .theirs(command: "bash ~/mine.sh"))

        try installer.connectStatusLine(senderPath: sender.path)

        XCTAssertEqual(installer.statusLineState(), .connected)
        var connected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
        if case var .object(root) = connected, case var .object(statusLine)? = root["statusLine"] {
            statusLine["command"] = .string("bash ~/mine.sh")
            root["statusLine"] = .object(statusLine)
            connected = .object(root)
        }
        XCTAssertEqual(connected, try JSONDecoder().decode(JSONValue.self, from: Data(original.utf8)))
        let relay = home.appendingPathComponent("Library/Application Support/AgentWatch/statusline-relay.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relay.path))
        XCTAssertEqual(
            try String(
                contentsOf: relay.deletingLastPathComponent().appendingPathComponent("original-command.txt"),
                encoding: .utf8),
            "bash ~/mine.sh",
            "the command is kept beside the script so a person can find it without the app"
        )

        // The settings file is not the app's, so every write into it is preceded by a copy.
        // This assertion used to live in the test for removing hooks left in the file by hand;
        // that feature is gone, and the promise is not.
        XCTAssertEqual(try Self.backups(of: settingsURL).count, 1)

        try installer.disconnectStatusLine()

        XCTAssertEqual(installer.statusLineState(), .theirs(command: "bash ~/mine.sh"))
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL)),
            try JSONDecoder().decode(JSONValue.self, from: Data(original.utf8))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: relay.path))
        XCTAssertEqual(try Self.backups(of: settingsURL).count, 2, "and giving it back is a change too")
    }

    func testDisconnectingAnOriginallyAbsentStatusLineRemovesOnlyTheAddedSlot() throws {
        let home = try makeHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"model":"opus"}"#.utf8)
        try original.write(to: settings)
        let installer = ToolingInstaller(home: home)
        try installer.connectStatusLine(senderPath: try makeSender(in: home).path)
        try installer.disconnectStatusLine()
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings)),
            try JSONDecoder().decode(JSONValue.self, from: original)
        )
    }

    /// Every copy `backUp` makes of one file, by the name it gives them.
    private static func backups(of url: URL) throws -> [String] {
        let name = url.lastPathComponent
        return try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("\(name).agentwatch-backup") }
    }

    /// The rule the app backs its promises with is "save a file before changing it when the
    /// content is not ours". `original-command.txt` sits in a folder the app owns, so it
    /// reads as ours — but what is written in it is a command a person wrote, and it is the
    /// only record of it. Disconnecting reads that file and nothing else.
    ///
    /// The way in is the case this app exists to survive: a person edits the settings file by
    /// hand. Take the `statusLine` key out after connecting, and the state reads `notSet`
    /// while the companion still holds their command. Connecting again then had nothing
    /// stopping it from writing an empty original over the real one, and the command was gone
    /// from the only place that had it.
    func testConnectingAgainDoesNotDiscardACommandTheCompanionFileStillHolds() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"model":"opus"}"#.utf8).write(to: settingsURL)

        let support = home.appendingPathComponent("Library/Application Support/AgentWatch")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let companion = support.appendingPathComponent("original-command.txt")
        try Data("bash ~/mine.sh".utf8).write(to: companion)

        let installer = ToolingInstaller(home: home)
        try installer.connectStatusLine(senderPath: sender.path)

        let saved = try FileManager.default.contentsOfDirectory(atPath: support.path)
            .filter { $0.hasPrefix("original-command.txt.agentwatch-backup") }
        XCTAssertEqual(saved.count, 1, "the only record of their command must be saved first")
        let backup = try XCTUnwrap(saved.first)
        XCTAssertEqual(
            try String(contentsOf: support.appendingPathComponent(backup), encoding: .utf8),
            "bash ~/mine.sh"
        )
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

    /// A settings file that is there but does not parse is not the same thing as no settings
    /// file, and the difference is somebody's whole configuration. Reading them as one meant
    /// starting from an empty object and writing that back, so a half-written file — the
    /// state an interrupted write leaves — cost a person their model, their permissions and
    /// every MCP server the file named.
    func testAnUnreadableSettingsFileStopsTheWriteInsteadOfReplacingIt() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Truncated rather than merely odd: this decoder accepts a trailing comma, so a file
        // with one is not in fact unreadable and would prove nothing.
        let theirs = #"{"model":"opus","permissions":{"allow":["Bash""#
        try Data(theirs.utf8).write(to: settingsURL)
        let installer = ToolingInstaller(home: home)

        XCTAssertThrowsError(try installer.connectStatusLine(senderPath: sender.path))
        XCTAssertEqual(
            try String(contentsOf: settingsURL, encoding: .utf8),
            theirs,
            "the file the app could not understand must be exactly as it was"
        )
    }

    /// The same rule for the other file the app writes into but does not own. Codex has no
    /// plugins, so its hooks are merged in beside somebody else's — and a merge into a file
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
    /// are unknown. Both hook files and the status-line slot answer the same way.
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
        XCTAssertEqual(installer.statusLineState(), .unreadable)
        XCTAssertFalse(
            ToolingInstallationState.unreadable.wantsInstalling,
            "pressing the line must not write over a file whose contents nobody knows"
        )
    }

    /// Disconnecting promises to give the slot back exactly as it was found, and the command
    /// it gives back comes from a file beside the relay. With that file gone — a cleaned
    /// support folder, a write that failed — an empty answer used to mean "remove the key",
    /// so the one operation that promised to restore a person's status line destroyed it.
    func testDisconnectingRefusesWhenTheCommandItWouldGiveBackIsMissing() throws {
        let home = try makeHome()
        let sender = try makeSender(in: home)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"statusLine":{"type":"command","command":"bash ~/mine.sh"}}"#.utf8)
            .write(to: settingsURL)
        let installer = ToolingInstaller(home: home)
        try installer.connectStatusLine(senderPath: sender.path)

        let companion = home.appendingPathComponent(
            "Library/Application Support/AgentWatch/original-command.txt")
        try FileManager.default.removeItem(at: companion)

        XCTAssertThrowsError(try installer.disconnectStatusLine())
        XCTAssertEqual(
            installer.statusLineState(),
            .connected,
            "refusing leaves the relay in place, which still runs their command"
        )
    }

    // MARK: - Helpers

    /// The relay script names a sender, and a copy running in a sandbox owns a different
    /// sender from the one the real folder knows about. So the folder follows the app, not
    /// the home — unless this installer was handed a home of its own, which is what every
    /// test above does.
    func testTheAppsOwnFolderFollowsTheAppUnlessAHomeWasHandedIn() throws {
        let home = try makeHome()

        XCTAssertEqual(
            ToolingInstaller(home: home).supportDirectory,
            home.appendingPathComponent("Library/Application Support/AgentWatch", isDirectory: true),
            "given a home, everything is under it"
        )
        XCTAssertEqual(
            ToolingInstaller().supportDirectory,
            try XCTUnwrap(AgentWatchPaths.applicationSupportDirectory())
                .appendingPathComponent("AgentWatch", isDirectory: true),
            "given none, the folder is the one every other store here resolves"
        )
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
