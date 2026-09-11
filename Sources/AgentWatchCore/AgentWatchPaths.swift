import Foundation

/// The files Agent Watch keeps for itself, named in one place.
///
/// The app creates a socket and the hook sender goes looking for it — from another target,
/// in a process that starts and dies inside a second, with nothing connecting them but an
/// agreement about a name. That agreement belongs in one file, because a mismatch says
/// nothing: hooks are fail-open by design, so nothing errors, nothing is logged, and the
/// widget simply sits empty — which is the one state the app is built to tell apart from
/// good news.
public enum AgentWatchPaths {
    /// Everything the app keeps lives under this one folder.
    ///
    /// - Parameter applicationSupport: the enclosing directory, taken as a parameter so a
    ///   test can put it somewhere that is not the running person's Application Support.
    public static func supportDirectory(inApplicationSupport applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("AgentWatch", isDirectory: true)
    }

    /// The user's own Application Support folder, or `nil` when the system will not name one.
    ///
    /// A debug build takes `AGENT_WATCH_SUPPORT_DIR` instead when it is set. That is what lets
    /// a test copy run beside the real one: everything the app keeps hangs off this folder —
    /// the socket, the lock beside it, the settings, the remembered sessions — so one
    /// substitution moves all of it, and the two copies never compete for the same socket.
    /// A release build ignores the variable entirely: a stray value in somebody's environment
    /// would hide their settings with no way to tell why.
    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL? {
        #if DEBUG
            let sandbox = ProcessInfo.processInfo.environment["AGENT_WATCH_SUPPORT_DIR"]
            if let sandbox, !sandbox.isEmpty {
                return URL(fileURLWithPath: sandbox, isDirectory: true)
            }
        #endif
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The socket the running instance listens on and a hook expects to find. One name,
    /// because one Agent Watch runs at a time — the lock beside it is what guarantees that.
    ///
    /// Takes Agent Watch's own folder rather than the one enclosing it, because that is the
    /// folder callers already hold — and it is the one a test can replace.
    public static func socketURL(inDirectory directory: URL) -> URL {
        directory.appendingPathComponent("agent-watch.sock", isDirectory: false)
    }

    /// Where the IDE plugin says it is loaded, one file per IDE.
    ///
    /// The same agreement about a name as the socket above, and for the same reason: the two
    /// sides are different programs in different languages that never meet. The plugin
    /// arrives at this path from `PathManager.getConfigPath()` inside the IDE; Agent Watch
    /// arrives at it from `dataDirectoryName` in the IDE's bundle. Neither can ask the other.
    public static func idePluginReplyFile(inDirectory directory: URL, dataDirectoryName: String) -> URL {
        directory
            .appendingPathComponent("ide-plugins", isDirectory: true)
            .appendingPathComponent("\(dataDirectoryName).json", isDirectory: false)
    }

    /// Where the IDE plugin's own file waits to be installed from.
    ///
    /// Agent Watch does not carry the plugin inside its own bundle: the IDE installs it, the
    /// two are versioned separately, and a copy welded into the application would go stale
    /// the moment either moved. So there is one directory the app owns and reads, and how a
    /// file arrives in it is somebody else's business — a release downloaded from the
    /// project's page, or a build put there by hand while the plugin is being written. From
    /// here both look identical, which is the point.
    public static func idePluginDirectory(inDirectory directory: URL) -> URL {
        directory.appendingPathComponent("ide-plugin", isDirectory: true)
    }
}
