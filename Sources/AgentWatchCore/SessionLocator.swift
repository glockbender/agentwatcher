import Foundation

/// A project one of the JetBrains IDEs knows about, as its own recent-projects file lists it.
///
/// Read rather than guessed: the file is how the IDE itself answers "which project owns this
/// directory", and it costs no permission — see `docs/session-focus-research.md`.
public struct KnownProject: Equatable, Sendable {
    /// Absolute, with the file's `$USER_HOME$` macro already expanded.
    ///
    /// Kept inside this process and never published: ADR-0001 allows a
    /// project *name* to leave and no path with it. What leaves is `name`.
    public let path: String
    /// What the IDE last wrote in that project's window title, if it wrote one. It carries
    /// the file that was open at the time, so it is a hint for a person's eye rather than an
    /// identifier.
    ///
    /// Read but not yet used: nothing displays it and nothing matches on it. It is kept
    /// because picking one window out of an IDE's several is the job the plugin exists for,
    /// and this is the only thing the file says about a window. Until that is wired up, it is
    /// a parsed field with no reader.
    public let windowTitle: String?
    /// Whether the file says the project was open. Written when the IDE feels like it, so
    /// this is the file's last opinion and not a live fact.
    public let isOpen: Bool

    public init(path: String, windowTitle: String?, isOpen: Bool) {
        self.path = path
        self.windowTitle = windowTitle
        self.isOpen = isOpen
    }

    /// The last component of the path, which is the only part of it allowed to be shown.
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Reads `recentProjects.xml`, the file every JetBrains IDE keeps beside its settings.
///
/// Takes bytes somebody else read, per `AGENTS.md`: the file system is not the subject here,
/// the shape of one XML file is.
public enum JetBrainsRecentProjects {
    /// The macro the file writes instead of the home directory.
    private static let homeMacro = "$USER_HOME$"

    public static func parse(_ data: Data, userHome: String) -> [KnownProject] {
        let reader = Reader(userHome: userHome)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        // The result is deliberately ignored: a half-read file gives back what it managed to
        // say. The alternative is nothing, and nothing here means a person is told less about
        // their own session for no gain — every entry that did parse is still true. Written as
        // a `guard` with both branches returning the same thing, which read as a decision
        // being made.
        _ = parser.parse()
        return reader.projects
    }

    /// Expands the one macro the file uses. Anything else is already absolute.
    static func expand(_ key: String, userHome: String) -> String {
        guard key.hasPrefix(homeMacro) else {
            return key
        }
        return userHome + key.dropFirst(homeMacro.count)
    }

    /// The file is `<entry key="…"><value><RecentProjectMetaInfo …>`, so the key arrives one
    /// element before the attributes it belongs to. Holding the key until then is the whole
    /// state this reader keeps.
    private final class Reader: NSObject, XMLParserDelegate {
        private let userHome: String
        private var pendingKey: String?
        private(set) var projects: [KnownProject] = []

        init(userHome: String) {
            self.userHome = userHome
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "entry":
                pendingKey = attributes["key"]
            case "RecentProjectMetaInfo":
                guard let key = pendingKey else {
                    return
                }
                pendingKey = nil
                projects.append(
                    KnownProject(
                        path: JetBrainsRecentProjects.expand(key, userHome: userHome),
                        windowTitle: attributes["frameTitle"],
                        isOpen: attributes["opened"] == "true"
                    )
                )
            default:
                break
            }
        }
    }
}

/// Which project a working directory belongs to.
public enum SessionPlace {
    /// The project whose directory contains this one: an open one first, then the longest
    /// match.
    ///
    /// Longest, because nesting is real: a repository checked out inside another one would
    /// otherwise be reported as its parent. Compared component by component, so `/src/app`
    /// does not claim a session working in `/src/application`.
    ///
    /// Open first, because the answer is used to point at a **window**. A closed inner
    /// project is the better description of where the files are and the worse answer to
    /// "which window", and the caller asked the second question.
    public static func project(containing workingDirectory: String, among projects: [KnownProject]) -> KnownProject? {
        let directory = components(of: workingDirectory)
        return
            projects
            .filter { contains(components(of: $0.path), directory) }
            .max { left, right in
                if left.isOpen != right.isOpen {
                    return right.isOpen
                }
                return components(of: left.path).count < components(of: right.path).count
            }
    }

    /// A path as the components that carry meaning, with `.` and `..` folded away.
    ///
    /// Folded here rather than by `URL.standardizedFileURL`, which is documented as possibly
    /// consulting the file system. This is `AgentWatchCore`, where `AGENTS.md` asks for a
    /// rule stated over the bytes somebody else read and tested without a disk — and a
    /// matching rule that may ask the file system is one whose answer can differ between
    /// this machine and the next.
    private static func components(of path: String) -> [String] {
        var folded: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                // With nothing to step out of, it is kept: dropping it would fold two
                // different paths onto the same components and match a session to a project
                // it is not in.
                if let last = folded.last, last != ".." {
                    folded.removeLast()
                } else {
                    folded.append(component)
                }
            default:
                folded.append(component)
            }
        }
        return folded
    }

    private static func contains(_ project: [String], _ directory: [String]) -> Bool {
        project.count <= directory.count && Array(directory.prefix(project.count)) == project
    }
}

/// Everything Agent Watch can honestly say about where a session is, and how precisely.
///
/// A value rather than a boolean because the boolean it replaces answered a different
/// question than the one a person asks. "Can this be raised" decided whether a button was
/// grey; what a person needs is "where is it, and how close can you get me" — and the answer
/// is worth saying even when nothing can be pressed.
public struct SessionLocator: Equatable, Sendable {
    /// The application hosting the session, as a person sees it named.
    public let applicationName: String?
    /// The name of the project **window** to look at, when one is known: the directory's
    /// name, never its path — ADR-0001. Absent for a host that keeps no
    /// project list, and for a project nothing says is open — a name here is a promise that
    /// there is a window wearing it.
    public let projectName: String?
    /// The name the session's tab carries, which is the session's own name: Claude writes it
    /// into the terminal title itself. See `docs/session-focus-research.md`.
    public let tabName: String?

    public init(
        applicationName: String?,
        projectName: String? = nil,
        tabName: String? = nil
    ) {
        self.applicationName = applicationName
        self.projectName = projectName
        self.tabName = tabName
    }

    /// Nothing is known, because the host is gone.
    public static let nowhere = SessionLocator(applicationName: nil)
}
