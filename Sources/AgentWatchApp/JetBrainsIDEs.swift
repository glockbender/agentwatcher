import AgentWatchCore
import AppKit

/// One JetBrains IDE installed on this machine.
struct InstalledJetBrainsIDE: Equatable {
    let product: JetBrainsProduct
    let bundlePath: String
    /// From the bundle's `CFBundleURLSchemes` — `goland`, `idea`. Missing means no address
    /// can name this IDE, which is a state the window has a sentence for.
    let productScheme: String?
    /// Running now. It decides what may be asked of this IDE rather than how it is described:
    /// opening a `jetbrains://` address at an IDE that is not running starts it, and starting
    /// somebody's IDE because they opened a settings window would be a surprise.
    let isRunning: Bool

    var name: String {
        guard let version = product.version else {
            return product.name
        }
        return "\(product.name) \(version)"
    }
}

/// Finding the JetBrains IDEs a person has, from the bundles rather than from the settings.
///
/// The settings directory `~/Library/Application Support/JetBrains/<product><version>` stays
/// behind when an IDE is deleted, so a list built from it names IDEs that are not there. A
/// bundle carrying `product-info.json` is an IDE by definition, and the same file names the
/// settings directory — which is the name the plugin's reply file is keyed by.
///
/// Nothing here is cached. Every reading is a reading of now: an IDE updated between two
/// openings of this window has a **different** settings directory, so a remembered answer
/// would report a plugin that the new version never loaded. That is the mistake the focus
/// button made — an answer computed once — and `docs/implementation-plan.md` names it.
@MainActor
enum JetBrainsIDEs {
    /// Every IDE this machine has, the running ones first.
    static func installed(fileManager: FileManager = .default) -> [InstalledJetBrainsIDE] {
        let running = runningBundlePaths()
        var found: [String: InstalledJetBrainsIDE] = [:]

        for bundle in candidateBundles(fileManager: fileManager, running: running) {
            guard let product = JetBrainsInstallation.product(ofApplicationAt: bundle, fileManager: fileManager) else {
                continue
            }
            let path = bundle.path
            let ide = InstalledJetBrainsIDE(
                product: product,
                bundlePath: path,
                productScheme: JetBrainsInstallation.productScheme(ofApplicationAt: bundle, fileManager: fileManager),
                isRunning: running.contains(path)
            )
            // Keyed by settings directory rather than by path, because one product installed
            // twice — an alias beside the bundle it points at, a copy in another folder —
            // shares one settings directory and one plugin, and two rows for it would read as
            // a fault. A running copy wins, since that is the one anything can be asked of.
            if let existing = found[product.dataDirectoryName], existing.isRunning, !ide.isRunning {
                continue
            }
            found[product.dataDirectoryName] = ide
        }

        return found.values.sorted { left, right in
            left.isRunning == right.isRunning ? left.name < right.name : left.isRunning
        }
    }

    /// Where the application folders are, plus whatever is already running.
    ///
    /// Running applications are in the list because no fixed set of folders is right: Toolbox
    /// has put its IDEs in more than one place over the years, and an IDE a person has open
    /// is one they have, wherever it lives.
    private static func candidateBundles(fileManager: FileManager, running: Set<String>) -> [URL] {
        var bundles: [URL] = running.map { URL(fileURLWithPath: $0) }
        for root in applicationFolders(fileManager: fileManager) {
            for entry in contents(of: root, fileManager: fileManager) {
                if entry.pathExtension == "app" {
                    bundles.append(entry)
                    continue
                }
                // One level deeper, and no further: Toolbox has kept its IDEs in a folder of
                // its own, and a full walk of `/Applications` would open every bundle on the
                // machine to ask whether it is an IDE.
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                bundles.append(
                    contentsOf: contents(of: entry, fileManager: fileManager).filter { $0.pathExtension == "app" })
            }
        }
        // Resolved, so an alias and its target are one path rather than two IDEs.
        var seen: Set<String> = []
        return bundles.map { $0.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }

    private static func applicationFolders(fileManager: FileManager) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    private static func contents(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func runningBundlePaths() -> Set<String> {
        Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleURL)
                .map { $0.resolvingSymlinksInPath().path }
        )
    }
}
