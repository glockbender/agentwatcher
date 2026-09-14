import AgentWatchCore
import Foundation

/// One JetBrains product, as its own bundle describes it.
struct JetBrainsProduct: Equatable {
    let name: String
    let version: String?
    /// The settings directory this exact product and version uses — `GoLand2026.1`. The name
    /// both sides of the IDE plugin meet on, and different for every version, which is why an
    /// IDE upgrade leaves the plugin unfound rather than silently carried over.
    let dataDirectoryName: String
}

/// What a JetBrains IDE on this machine will say about itself, for free.
///
/// Every IDE bundle carries `product-info.json`, and the one field that matters there is
/// `dataDirectoryName`: it names the settings directory this exact product and version uses,
/// which is where `recentProjects.xml` lives. Following the bundle to its settings is what
/// makes this work for whichever IDE a person actually has, without a table of bundle
/// identifiers to keep in step with JetBrains' catalogue — and without asking macOS for a
/// single permission. See `docs/session-focus-research.md`.
/// On the main actor for the cache alone: the one caller is the host registry, which is
/// already there, and a lock around a dictionary read on a hover would cost more than it
/// protects.
@MainActor
enum JetBrainsInstallation {
    /// Cached by settings directory and by the file's own modification date, so a hover
    /// costs a `stat` rather than a parse of forty kilobytes, and an IDE that has just
    /// opened a project is still read again.
    private struct CachedProjects {
        let modifiedAt: Date
        let projects: [KnownProject]
    }

    private static var cache: [String: CachedProjects] = [:]

    /// The projects the IDE in this bundle remembers, or nothing if the bundle is not a
    /// JetBrains IDE at all — which is how every other host answers.
    static func projects(ofApplicationAt bundleURL: URL, fileManager: FileManager = .default) -> [KnownProject] {
        guard let dataDirectoryName = dataDirectoryName(ofApplicationAt: bundleURL, fileManager: fileManager) else {
            return []
        }
        let file = settingsDirectory(named: dataDirectoryName, fileManager: fileManager)
            .appendingPathComponent("options/recentProjects.xml")

        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cache[dataDirectoryName], cached.modifiedAt == modifiedAt {
            return cached.projects
        }
        guard let data = try? Data(contentsOf: file) else {
            return []
        }
        // The same home the settings directory was found under, and not `NSHomeDirectory()`.
        // Two notions of home in one function means the injected `fileManager` can move the
        // file but not the macro inside it, so every expanded project path would miss and the
        // name would silently never appear — and under a sandbox, where `NSHomeDirectory()`
        // is the container, that is what happens without anything being injected at all.
        let projects = JetBrainsRecentProjects.parse(
            data,
            userHome: fileManager.homeDirectoryForCurrentUser.path
        )
        if let modifiedAt {
            cache[dataDirectoryName] = CachedProjects(modifiedAt: modifiedAt, projects: projects)
        }
        return projects
    }

    /// Reads the one field this needs out of the bundle's own description of itself.
    static func dataDirectoryName(ofApplicationAt bundleURL: URL, fileManager: FileManager = .default) -> String? {
        product(ofApplicationAt: bundleURL, fileManager: fileManager)?.dataDirectoryName
    }

    /// What a bundle says it is, or nothing when it is not a JetBrains IDE.
    ///
    /// The product's own name and version rather than the bundle's file name, because the two
    /// disagree exactly where it matters: a bundle renamed by hand, and two versions of one
    /// product installed side by side.
    static func product(ofApplicationAt bundleURL: URL, fileManager: FileManager = .default) -> JetBrainsProduct? {
        let productInfo = bundleURL.appendingPathComponent("Contents/Resources/product-info.json")
        guard
            let data = try? Data(contentsOf: productInfo),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataDirectoryName = parsed["dataDirectoryName"] as? String,
            !dataDirectoryName.isEmpty
        else {
            return nil
        }
        return JetBrainsProduct(
            name: (parsed["name"] as? String) ?? bundleURL.deletingPathExtension().lastPathComponent,
            version: parsed["version"] as? String,
            dataDirectoryName: dataDirectoryName
        )
    }

    /// The URL scheme this IDE registers for itself — `goland`, `pycharm`, `idea`.
    ///
    /// This is the product name the `jetbrains://` address needs, and the bundle is the only
    /// honest source for it. Deriving it from the product's name works for GoLand and breaks
    /// on the most common IDE of all: `IntelliJ IDEA` answers to `idea`.
    ///
    /// The scheme is not what opens the address — `jetbrains://` belongs to the JetBrains
    /// daemon — but it is how that address says which product it means.
    static func productScheme(ofApplicationAt bundleURL: URL, fileManager: FileManager = .default) -> String? {
        let infoPlist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlist),
            let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let urlTypes = parsed["CFBundleURLTypes"] as? [[String: Any]]
        else {
            return nil
        }
        return
            urlTypes
            .compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
            .first { !$0.isEmpty }
    }

    /// Whether the daemon that owns the `jetbrains://` scheme is installed for this person.
    static func isDaemonInstalled(fileManager: FileManager = .default) -> Bool {
        let bundle = JetBrainsFocus.daemonBundle(userHome: fileManager.homeDirectoryForCurrentUser)
        return fileManager.fileExists(atPath: bundle.path)
    }

    /// Whether the plugin has ever answered `ping` from the IDE in this bundle.
    ///
    /// The file is the plugin's own word that it was loaded there. It outlives the plugin —
    /// nothing deletes it when the plugin is removed — so this answers "has been seen", not
    /// "is there now". That is enough here, because a `focus` address that reaches an IDE
    /// without the plugin does nothing and says nothing. Freshness is the installation
    /// screen's question, and `docs/architecture.md` says so.
    static func hasAnsweredPing(ofApplicationAt bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        guard
            let dataDirectoryName = dataDirectoryName(ofApplicationAt: bundleURL, fileManager: fileManager),
            let support = AgentWatchPaths.supportDirectory(fileManager: fileManager)
        else {
            return false
        }
        let reply = AgentWatchPaths.idePluginReplyFile(
            inDirectory: support,
            dataDirectoryName: dataDirectoryName
        )
        return fileManager.fileExists(atPath: reply.path)
    }

    private static func settingsDirectory(named name: String, fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JetBrains")
            .appendingPathComponent(name)
    }
}
