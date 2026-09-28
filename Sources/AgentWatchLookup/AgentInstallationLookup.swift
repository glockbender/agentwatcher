import AgentWatchCore
import Foundation

/// Best-effort discovery without launching a shell or executing an agent.
/// Missing means "not found in these locations", never "cannot be installed".
public enum AgentInstallationLookup {
    public static func executable(
        for source: AgentSource,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        applications: [URL] = [URL(fileURLWithPath: "/Applications")]
    ) -> String? {
        let name = source.rawValue
        let directories =
            searchPath.split(separator: ":").map(String.init)
            + [
                home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".npm-global/bin").path,
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            ]
        var candidates = directories.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent(name)
        }
        let appDirectories = applications + [home.appendingPathComponent("Applications")]
        if source == .codex {
            candidates += appDirectories.map { $0.appendingPathComponent("Codex.app/Contents/Resources/codex") }
        }
        return candidates.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }?.path
    }
}
