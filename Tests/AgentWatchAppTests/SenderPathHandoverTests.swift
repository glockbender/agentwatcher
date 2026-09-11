import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The join between the two halves the rest of the tests cover separately.
///
/// `SenderLinkTests` proves the link is built correctly. `ToolingInstallerTests` proves the
/// agent's configuration records whatever path it was handed. Neither says the path handed
/// over is the link — and that is the whole point of having a link: an entry naming a build
/// directory dies with that build, and for Codex it costs a fresh trust approval every time
/// a person switches between the installed bundle and their own build.
@MainActor
final class SenderPathHandoverTests: XCTestCase {
    func testTheLinkIsWhatEndsUpInEachAgentsConfiguration() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let build = try makeBuild(named: "debug", in: home)

        let handedOver = SenderLink(directoryURL: support).refresh(forExecutableAt: build.executable)
        XCTAssertEqual(handedOver, .stable(support.appendingPathComponent("AgentWatchSend").path))

        let installer = ToolingInstaller(home: home)
        for source in AgentSource.allCases {
            try installer.installHooks(
                for: source,
                senderPath: handedOver.path,
                hooks: ToolingHooks.hooks(for: source)
            )

            let written = try Self.commands(inHooksAt: installer.hooksPath(for: source))
            XCTAssertFalse(written.isEmpty, "\(source) wrote no hook commands at all")
            for command in written {
                XCTAssertTrue(
                    command.hasPrefix(ShellWord.quoted(handedOver.path) + " "),
                    "\(source) registered \(command) instead of the stable link as one shell word"
                )
            }
            XCTAssertFalse(
                written.contains { $0.contains(build.sender.path) },
                "\(source) registered a path that dies with this build"
            )
        }
    }

    /// And the path that was written has to run something. A link is a name, and a name that
    /// resolves to nothing looks exactly like an idle machine: the hook succeeds, no event
    /// arrives, and nothing anywhere says why.
    func testThePathWrittenIntoAConfigurationRunsSomething() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let build = try makeBuild(named: "debug", in: home)

        let handedOver = SenderLink(directoryURL: support).refresh(forExecutableAt: build.executable)
        let installer = ToolingInstaller(home: home)
        try installer.installHooks(
            for: .codex,
            senderPath: handedOver.path,
            hooks: ToolingHooks.hooks(for: .codex)
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: handedOver.path))
        XCTAssertEqual(installer.hookState(for: .codex, delivery: .arrived), .installed)
    }

    /// What a person sees when the link stops resolving — the build it pointed at was cleaned
    /// away, and nothing has launched since to move it. The entries are ours and unchanged,
    /// so the only honest reading is that they cannot run.
    func testAConfigurationNamingALinkThatResolvesToNothingReadsAsStale() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let build = try makeBuild(named: "debug", in: home)

        let handedOver = SenderLink(directoryURL: support).refresh(forExecutableAt: build.executable)
        let installer = ToolingInstaller(home: home)
        try installer.installHooks(
            for: .codex,
            senderPath: handedOver.path,
            hooks: ToolingHooks.hooks(for: .codex)
        )
        XCTAssertEqual(installer.hookState(for: .codex, delivery: .arrived), .installed)

        try FileManager.default.removeItem(at: build.sender)

        XCTAssertEqual(
            installer.hookState(for: .codex, delivery: .arrived),
            .stale(senderPaths: [handedOver.path]),
            "a link with nothing behind it is a dead entry, and the menu has to name it"
        )
    }

    // MARK: - Helpers

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchHandoverTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One build's pair of files, the arrangement both `build-app.sh` and `swift build` leave.
    private func makeBuild(named name: String, in directory: URL) throws -> (executable: URL, sender: URL) {
        let buildDirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        let executable = buildDirectory.appendingPathComponent("AgentWatch")
        let sender = buildDirectory.appendingPathComponent("AgentWatchSend")
        try Data().write(to: executable)
        try Data().write(to: sender)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sender.path)
        return (executable, sender)
    }

    /// Every hook command in one agent's file, whichever shape that file has.
    private static func commands(inHooksAt url: URL) throws -> [String] {
        let document = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
        guard case let .object(root) = document, case let .object(events)? = root["hooks"] else {
            return []
        }
        return events.values.flatMap { groups -> [String] in
            guard case let .array(groupList) = groups else {
                return []
            }
            return groupList.flatMap { group -> [String] in
                guard case let .object(fields) = group, case let .array(entries)? = fields["hooks"] else {
                    return []
                }
                return entries.compactMap { entry in
                    guard case let .object(entryFields) = entry,
                        case let .string(command)? = entryFields["command"]
                    else {
                        return nil
                    }
                    return command
                }
            }
        }
    }
}
