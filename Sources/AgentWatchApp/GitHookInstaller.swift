import AgentWatchCore
import AgentWatchGit
import Darwin
import Foundation

/// Register the executable at its installed path. Updating the bundle never rewrites either profile.
struct GitHookInstaller {
    enum Action: String { case status, install, remove }
    enum State: String { case absent, registered, needsRepair }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    let bundle: URL

    private static let hookSuffix = "/Contents/Resources/GitProtection/hooks/git-guard.sh"
    private static let failedHook =
        #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Agent Watch Git: the installed hook could not run. Repair Git Hook in Agent Watch and try again."}}"#
    // Start the outer deadline before opening the bundle. The timer stops the launcher group
    // so the client gets a denial. The native hook bounds its own Git child processes.
    private static let hookLauncher = """
        set -m
        exec 3<&0
        /bin/bash "$@" <&3 3<&- &
        worker=$!
        (/bin/sleep 8; kill -KILL -- "-$worker" 2>/dev/null || :) 3<&- &
        timer=$!
        wait "$worker" 2>/dev/null
        status=$?
        kill -TERM -- "-$timer" 2>/dev/null || :
        wait "$timer" 2>/dev/null || :
        exit "$status"
        """

    static func checkLocation(_ location: URL, readOnly: Bool) throws {
        let parts = location.pathComponents
        let translocated = parts.indices.contains { i in
            parts[i] == "AppTranslocation" && i + 2 < parts.count
                && UUID(uuidString: parts[i + 1]) != nil && parts[i + 2] == "d"
        }
        if translocated || readOnly {
            throw Failure(
                "Copy Agent Watch to Applications or another permanent writable volume, then open that copy to install its Git hook."
            )
        }
    }

    private func checkBundle() throws {
        let location = bundle.resolvingSymlinksInPath()
        var fs = statfs()
        guard statfs(location.path, &fs) == 0 else {
            throw Failure("Could not identify the volume containing \(location.path).")
        }
        try Self.checkLocation(location, readOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0)
        let hook = bundle.path + Self.hookSuffix
        guard FileManager.default.isReadableFile(atPath: hook) else {
            throw Failure("This build is missing the Git protection hook: \(hook)")
        }
        let cli = bundle.appendingPathComponent("Contents/MacOS/AgentWatchGit")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure("This build is missing the executable Git protection tool: \(cli.path)")
        }
        let report = try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/bin/bash"), arguments: [hook, "--check"], in: location,
            environment: ["PATH": "/usr/bin:/bin"], timeout: 10, outputLimit: 8192)
        guard report.status == 0,
            String(decoding: report.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "agent-watch-git-hook-ok"
        else {
            throw Failure(
                "The bundled AgentWatchGit executable failed its startup check. Install a working copy of Agent Watch, then try again."
            )
        }
    }

    func apply(_ action: Action, source: AgentSource, profile: URL) throws -> State {
        if action == .install { try checkBundle() }
        let filename = source == .claude ? "settings.json" : "hooks.json"
        let url = profile.appendingPathComponent(filename).resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: profile.path) {
            guard action == .install else { return .absent }
            try FileManager.default.createDirectory(
                at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let lock = try AgentProfileLock(profile)
        defer { withExtendedLifetime(lock) {} }
        return try edit(action, source: source, url: url)
    }

    private func edit(_ action: Action, source: AgentSource, url: URL) throws -> State {
        func read() throws -> Data? {
            do { return try Data(contentsOf: url) } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile
            {
                return nil
            }
        }
        let original = try read()
        let invalid = Failure("Cannot safely edit the hooks in \(url.path).")
        var root: [String: Any] = [:]
        if let original {
            guard let value = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw invalid }
            root = value
        }
        var events = root["hooks"] as? [String: Any] ?? [:]
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw invalid }
        let old = events["PreToolUse"] as? [[String: Any]] ?? []
        guard events["PreToolUse"] == nil || events["PreToolUse"] is [[String: Any]] else { throw invalid }

        let hook = bundle.path + Self.hookSuffix
        let legacyPrefix = "/bin/bash "
        let prefix = legacyPrefix + "-c " + ShellWord.quoted(Self.hookLauncher) + " agent-watch-git "
        let hostArgument = source == .codex ? " --host codex" : ""
        let fallback = " || /usr/bin/printf '%s\\n' " + ShellWord.quoted(Self.failedHook)
        // The client can still receive a denial while the installed bundle is absent.
        let command = prefix + ShellWord.quoted(hook) + hostArgument + fallback
        let entry: [String: Any] = ["type": "command", "command": command, "timeout": 10]
        let owned: [String: Any] = ["matcher": "Bash", "hooks": [entry]]
        func isOurCommand(_ value: [String: Any]) -> Bool {
            guard value["type"] as? String == "command", let command = value["command"] as? String
            else { return false }
            let currentFormat = command.hasPrefix(prefix) && command.hasSuffix(fallback)
            let text = currentFormat ? String(command.dropLast(fallback.count)) : command
            let start = currentFormat ? prefix : legacyPrefix
            guard text.hasPrefix(start), text.hasSuffix(hostArgument) else { return false }
            let word = String(text.dropFirst(start.count).dropLast(hostArgument.count))
            let script = ShellWord.unquoted(word)
            guard ShellWord.quoted(script) == word else { return false }
            let movedBundleSuffix = (currentFormat ? ".app" : "/AgentWatch.app") + Self.hookSuffix
            return script == hook || (script.hasPrefix("/") && script.hasSuffix(movedBundleSuffix))
        }
        var ourIndexes: [Int] = []
        for (index, group) in old.enumerated() {
            guard let list = group["hooks"] as? [[String: Any]] else { throw invalid }
            guard list.contains(where: isOurCommand) else { continue }
            guard group.count == 2, group["matcher"] as? String == "Bash", list.count == 1,
                Set(list[0].keys).isSubset(of: ["command", "type", "timeout"])
            else {
                if action == .status { return .needsRepair }
                throw Failure(
                    "A Git hook was customized in \(url.path). Put it in its own Bash group before editing it here.")
            }
            ourIndexes.append(index)
        }
        let state: State =
            ourIndexes.isEmpty
            ? .absent
            : (ourIndexes.count == 1 && NSDictionary(dictionary: old[ourIndexes[0]]).isEqual(to: owned)
                ? .registered : .needsRepair)
        guard action != .status else { return state }
        if action == .install {
            if state == .registered { return state }
        } else if state == .absent {
            return state
        }

        var groups = old
        for i in ourIndexes.reversed() {
            if action == .install && i == ourIndexes.first {
                groups[i] = owned
            } else if source == .codex && i != groups.count - 1 {
                // Codex indexes trust by group position. Later user hooks retain their slot.
                groups[i] = ["matcher": "Bash", "hooks": []]
            } else {
                groups.remove(at: i)
            }
        }
        if action == .install && ourIndexes.isEmpty { groups.append(owned) }
        if groups.isEmpty { events.removeValue(forKey: "PreToolUse") } else { events["PreToolUse"] = groups }
        if events.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = events }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard try read() == original else { throw Failure("The profile changed during editing. Try again.") }
        try data.write(to: url, options: .atomic)
        return action == .install ? .registered : .absent
    }
}

/// Agent Watch's independent installers merge into the same client profiles.
final class AgentProfileLock {
    private let descriptor: Int32

    init(_ folder: URL) throws {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw GitHookInstaller.Failure("Could not open profile folder: \(folder.path)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw GitHookInstaller.Failure("Another update is editing this profile. Try again.")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
