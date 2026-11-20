import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchApp

final class GitHookInstallerTests: XCTestCase {
    private var root: URL!
    private var app: URL!
    private var installer: GitHookInstaller { GitHookInstaller(bundle: app) }

    override func setUpWithError() throws {
        let scratch =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = scratch.appendingPathComponent(UUID().uuidString)
        app = root.appendingPathComponent("Agent Watch's Test.app")
        for name in [
            "Contents/Resources/GitProtection/hooks/git-guard.sh",
            "Contents/MacOS/AgentWatchGit",
        ] {
            let file = app.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content =
                name.hasSuffix("/git-guard.sh")
                ? "#!/bin/bash\n[[ \"$1\" == --check ]] && echo agent-watch-git-hook-ok\n" : "# Test fixture\n"
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }

    func testTwoProfilesSurviveBundleUpdateAndRepeatedInstallWithoutRewriting() throws {
        for source in AgentSource.allCases {
            let profile = root.appendingPathComponent("." + source.rawValue)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let config = profile.appendingPathComponent(source == .claude ? "settings.json" : "hooks.json")
            let original =
                #"{"limit":9007199254740993,"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo user-command"}]}]}}"#
            try Data(original.utf8).write(to: config)
            let toml = profile.appendingPathComponent("config.toml")
            try Data("# user-owned trust decisions\n".utf8).write(to: toml)
            XCTAssertEqual(try installer.apply(.install, source: source, profile: profile), .registered)
            let installed = try Data(contentsOf: config)
            XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("9007199254740993"))
            try Data("#!/bin/sh\n# Updated helper\n".utf8).write(
                to: app.appendingPathComponent("Contents/MacOS/AgentWatchGit"))
            XCTAssertEqual(try installer.apply(.status, source: source, profile: profile), .registered)
            XCTAssertEqual(try installer.apply(.install, source: source, profile: profile), .registered)
            XCTAssertEqual(try Data(contentsOf: config), installed)
            XCTAssertEqual(try installer.apply(.remove, source: source, profile: profile), .absent)
            let final = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary)
            XCTAssertEqual(final, try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary)
            XCTAssertEqual(try Data(contentsOf: toml), Data("# user-owned trust decisions\n".utf8))
        }
    }

    func testBothProfilesDenyWhenTheInstalledHookIsMissingOrTimesOut() throws {
        var commands: [String] = []
        for source in AgentSource.allCases {
            let profile = root.appendingPathComponent("." + source.rawValue)
            XCTAssertEqual(try installer.apply(.install, source: source, profile: profile), .registered)
            let config = profile.appendingPathComponent(source == .claude ? "settings.json" : "hooks.json")
            let profileJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            let events = try XCTUnwrap(profileJSON["hooks"] as? [String: [[String: Any]]])
            let entries = try XCTUnwrap(events["PreToolUse"]?.first?["hooks"] as? [[String: Any]])
            commands.append(try XCTUnwrap(entries.first?["command"] as? String))
        }

        func assertDenial(_ command: String) throws {
            let shell = Process()
            let output = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/bash")
            shell.arguments = ["-c", command]
            shell.standardOutput = output
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            XCTAssertEqual(shell.terminationStatus, 0)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
            XCTAssertEqual(json["hookSpecificOutput"]?["permissionDecision"], "deny")
        }

        let hook = app.appendingPathComponent("Contents/Resources/GitProtection/hooks/git-guard.sh")
        try FileManager.default.moveItem(at: hook, to: root.appendingPathComponent("moved-hook"))
        for command in commands { try assertDenial(command) }

        try Data("/bin/sleep 20\n".utf8).write(to: hook)
        try assertDenial(XCTUnwrap(commands.first))
    }

    func testRepairAfterMovingARenamedBundleReplacesTheOldHook() throws {
        let profile = root.appendingPathComponent(".codex")
        XCTAssertEqual(try installer.apply(.install, source: .codex, profile: profile), .registered)
        let moved = root.appendingPathComponent("Moved Agent Watch.app")
        try FileManager.default.moveItem(at: app, to: moved)
        let relocated = GitHookInstaller(bundle: moved)
        XCTAssertEqual(try relocated.apply(.status, source: .codex, profile: profile), .needsRepair)
        XCTAssertEqual(try relocated.apply(.install, source: .codex, profile: profile), .registered)
        let data = try Data(contentsOf: profile.appendingPathComponent("hooks.json"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(config["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(events["PreToolUse"]?.count, 1)
    }

    @MainActor func testMonitoringCanBeRemovedAndReinstalledWithoutMovingGitTrust() throws {
        let profile = root.appendingPathComponent(".codex")
        let monitoring = ToolingInstaller(home: root)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        func installMonitoring() throws {
            try monitoring.installHooks(
                for: .codex, in: profile, senderPath: "/tmp/AgentWatchSend", hooks: ["PreToolUse"])
        }
        let config = profile.appendingPathComponent("hooks.json")
        try installMonitoring()
        _ = try installer.apply(.install, source: .codex, profile: profile)
        func groups() throws -> [[String: Any]] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            return try XCTUnwrap((root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        }
        let original = try XCTUnwrap(groups().last) as NSDictionary
        try monitoring.removeHooks(for: .codex, in: profile)
        XCTAssertEqual(try groups()[1] as NSDictionary, original)
        try installMonitoring()
        XCTAssertEqual(try groups()[1] as NSDictionary, original)
        let later = try groups()[2] as NSDictionary
        _ = try installer.apply(.remove, source: .codex, profile: profile)
        XCTAssertEqual(try groups()[2] as NSDictionary, later)
    }

    func testInvalidExistingHookListIsLeftIntact() throws {
        let file = root.appendingPathComponent("settings.json")
        let content = Data(#"{"hooks":{"PreToolUse":{"unknown":12}}}"#.utf8)
        try content.write(to: file)
        XCTAssertThrowsError(try installer.apply(.install, source: .claude, profile: root))
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    func testLegacyWarningRequiresAnEnabledPluginWithTheGitHook() throws {
        let profile = root.appendingPathComponent("legacy")
        let plugin = profile.appendingPathComponent("plugins/cache/mothership/mothership/1")
        let manifest = plugin.appendingPathComponent(".claude-plugin/plugin.json")
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hook =
            #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/git-guard.sh\""}]}]}}"#
        try Data(hook.utf8).write(to: manifest)
        let registry = try JSONSerialization.data(withJSONObject: [
            "plugins": ["mothership@mothership": [["scope": "user", "installPath": plugin.path]]]
        ])
        try registry.write(to: profile.appendingPathComponent("plugins/installed_plugins.json"))
        XCTAssertEqual(MothershipGitRegistration.check(source: .claude, profile: profile), .absent)
        try Data(#"{"enabledPlugins":{"mothership@mothership":true}}"#.utf8)
            .write(to: profile.appendingPathComponent("settings.json"))
        XCTAssertEqual(MothershipGitRegistration.check(source: .claude, profile: profile), .registered)
        try Data(#"{"hooks":{"PreToolUse":[]}}"#.utf8).write(to: manifest)
        XCTAssertEqual(MothershipGitRegistration.check(source: .claude, profile: profile), .absent)
    }

    func testCustomGroupIsNotOverwrittenOrDuplicated() throws {
        XCTAssertEqual(try installer.apply(.install, source: .claude, profile: root), .registered)
        let file = root.appendingPathComponent("settings.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: #""matcher" : "Bash""#, with: #""matcher" : "Bash", "if": "custom condition""#)
        try Data(text.utf8).write(to: file)
        XCTAssertEqual(try installer.apply(.status, source: .claude, profile: root), .needsRepair)
        XCTAssertThrowsError(try installer.apply(.install, source: .claude, profile: root))
        XCTAssertThrowsError(try installer.apply(.remove, source: .claude, profile: root))
        XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
    }

    func testRequiresPermanentLocationAndAllowsWritableExternalVolume() throws {
        let external = URL(fileURLWithPath: "/Volumes/External/AgentWatch.app")
        XCTAssertNoThrow(try GitHookInstaller.checkLocation(external, readOnly: false))
        XCTAssertThrowsError(try GitHookInstaller.checkLocation(external, readOnly: true))
        let moved = URL(
            fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/\(UUID().uuidString)/d/AgentWatch.app")
        XCTAssertThrowsError(try GitHookInstaller.checkLocation(moved, readOnly: false))
    }

    func testInstallReportsExactlyWhichBundledToolIsMissingBeforeWritingProfile() throws {
        let profile = root.appendingPathComponent("unused-profile")
        for name in [
            "Contents/Resources/GitProtection/hooks/git-guard.sh",
            "Contents/MacOS/AgentWatchGit",
        ] {
            let file = app.appendingPathComponent(name)
            let moved = file.appendingPathExtension("missing")
            try FileManager.default.moveItem(at: file, to: moved)
            XCTAssertThrowsError(try installer.apply(.install, source: .claude, profile: profile)) {
                XCTAssertTrue($0.localizedDescription.contains(file.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
            try FileManager.default.moveItem(at: moved, to: file)
        }
    }

    func testInstallRequiresPositiveReadinessAndRemovalCanRecoverFromBrokenChecker() throws {
        let profile = root.appendingPathComponent("checker-profile")
        XCTAssertEqual(try installer.apply(.install, source: .codex, profile: profile), .registered)
        let hooks = profile.appendingPathComponent("hooks.json")
        let before = try Data(contentsOf: hooks)
        let launcher = app.appendingPathComponent("Contents/Resources/GitProtection/hooks/git-guard.sh")
        for response in ["exit 1", "echo '{\"permissionDecision\":\"deny\"}'"] {
            try Data(("#!/bin/bash\n" + response).utf8).write(to: launcher)
            XCTAssertThrowsError(try installer.apply(.install, source: .codex, profile: profile)) {
                XCTAssertTrue($0.localizedDescription.contains("AgentWatchGit"))
            }
            XCTAssertEqual(try Data(contentsOf: hooks), before)
        }
        XCTAssertEqual(try installer.apply(.status, source: .codex, profile: profile), .registered)
        XCTAssertEqual(try installer.apply(.remove, source: .codex, profile: profile), .absent)
    }

}
