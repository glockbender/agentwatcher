import AgentWatchCore
import AgentWatchGit
import AgentWatchLookup
import Foundation

enum MothershipGitRegistration {
    enum State { case registered, absent, unknown }

    static func check(source: AgentSource, profile: URL) -> State {
        let id = "mothership@mothership"
        do {
            let plugin: URL
            switch source {
            case .claude:
                let settings = try object(in: profile.appendingPathComponent("settings.json"))
                guard let enabled = settings["enabledPlugins"] as? [String: Any], enabled[id] as? Bool == true else {
                    return .absent
                }
                let registry = try object(in: profile.appendingPathComponent("plugins/installed_plugins.json"))
                guard let records = registry["plugins"] as? [String: [[String: Any]]],
                    let path = records[id]?.first(where: { $0["scope"] as? String == "user" })?["installPath"]
                        as? String
                else { return .unknown }
                plugin = URL(fileURLWithPath: path)
            case .codex:
                let cache = profile.appendingPathComponent("plugins/cache/mothership/mothership")
                guard FileManager.default.fileExists(atPath: cache.path) else { return .absent }
                guard let executable = AgentInstallationLookup.executable(for: .codex) else { return .unknown }
                let result = try BoundedCommand.run(
                    executable: URL(fileURLWithPath: executable),
                    arguments: ["plugin", "list", "--json", "--marketplace", "mothership"], in: profile,
                    environment: [
                        "CODEX_HOME": profile.path, "HOME": profile.deletingLastPathComponent().path,
                        "PATH": "/usr/bin:/bin",
                    ],
                    timeout: 5)
                guard result.status == 0,
                    let records = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
                    let installed = records["installed"] as? [[String: Any]]
                else { return .unknown }
                guard
                    let record = installed.first(where: {
                        $0["pluginId"] as? String == id && $0["enabled"] as? Bool == true
                    })
                else { return .absent }
                guard let version = record["version"] as? String, !version.contains("/"), !version.hasPrefix(".") else {
                    return .unknown
                }
                plugin = cache.appendingPathComponent(version)
            }
            let manifest = try object(in: plugin.appendingPathComponent(".\(source.rawValue)-plugin/plugin.json"))
            let hooks: [String: Any]
            if let inline = manifest["hooks"] as? [String: Any] {
                hooks = inline
            } else {
                let path = manifest["hooks"] as? String ?? "hooks/hooks.json"
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return .unknown }
                let file = try object(in: plugin.appendingPathComponent(path))
                hooks = file["hooks"] as? [String: Any] ?? [:]
            }
            let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let registered = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("${CLAUDE_PLUGIN_ROOT}/hooks/git-guard.sh") == true
                }
            }
            return registered ? .registered : .absent
        } catch { return .unknown }
    }

    private static func object(in url: URL) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
