import AgentWatchCore
import Foundation

/// The two files the installation section reads: what the plugin answered, and the plugin
/// itself waiting to be installed.
///
/// Both are read on every rebuild of the window. They belong to other programs and other
/// moments — one is written by an IDE, the other arrives by download or by hand — so a value
/// kept here would describe the last time this app looked.
@MainActor
enum IDEPluginFiles {
    /// What the plugin last wrote for this IDE, if it ever has.
    static func reply(forDataDirectoryName name: String, fileManager: FileManager = .default) -> IDEPluginReply? {
        guard let directory = AgentWatchPaths.supportDirectory(fileManager: fileManager) else {
            return nil
        }
        let file = AgentWatchPaths.idePluginReplyFile(inDirectory: directory, dataDirectoryName: name)
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }
        return IDEPluginReply.parse(data)
    }

    /// The plugin file an IDE would be pointed at, and where it is.
    static func staged(fileManager: FileManager = .default) -> (plugin: StagedIDEPlugin, path: String)? {
        guard let directory = pluginDirectory(fileManager: fileManager) else {
            return nil
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let plugin = IDEPluginInstallation.stagedPlugin(among: names) else {
            return nil
        }
        return (plugin, directory.appendingPathComponent(plugin.fileName, isDirectory: false).path)
    }

    /// Named, never created: whatever puts a file here makes it — `task plugin` today, a
    /// download later. The window says where it is whether or not anything is in it, because
    /// it is also the one place a person can put a plugin file for the app to find.
    static func pluginDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = AgentWatchPaths.supportDirectory(fileManager: fileManager) else {
            return nil
        }
        return AgentWatchPaths.idePluginDirectory(inDirectory: support)
    }
}
