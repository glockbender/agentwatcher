import AgentWatchCore
import Foundation

/// Best-effort discovery without launching a shell or executing an agent.
/// Missing means "not found in these locations", never "cannot be installed".
///
/// The places are written out because an app started from Finder gets launchd's `PATH`, which
/// holds none of them: the ones a person's shell adds are the ones where agents live.
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
            + homeDirectories(for: source, home: home)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
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

    /// Where installers and Node version managers put an agent under the home directory: the
    /// native installer, a global npm prefix, Claude's older local install, Volta, Bun, and
    /// every Node that nvm holds, newest-named first.
    private static func homeDirectories(for source: AgentSource, home: URL) -> [String] {
        var directories = [".local/bin", ".npm-global/bin"]
        if source == .claude {
            directories.append(".claude/local")
        }
        directories += [".volta/bin", ".bun/bin"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        directories += versions.sorted(by: >).map { ".nvm/versions/node/\($0)/bin" }
        return directories.map { home.appendingPathComponent($0).path }
    }
}
