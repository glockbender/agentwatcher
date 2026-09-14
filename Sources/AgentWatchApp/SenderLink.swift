import AgentWatchCore
import Darwin
import Foundation

/// What another program will be told to run, and whether that answer outlives this build.
enum SenderPath: Equatable {
    /// The link. Survives a switch between builds, so the configuration holding it never
    /// has to be rewritten.
    case stable(String)
    /// The build's own sender, named because the link could not be made. Works now and stops
    /// working when this build goes away.
    case tiedToThisBuild(String)

    var path: String {
        switch self {
        case let .stable(path), let .tiedToThisBuild(path): path
        }
    }
}

/// The one path Agent Watch asks another program to run.
struct SenderLink {
    private let directoryURL: URL?

    /// - Parameter directoryURL: where the link lives. Given only by tests; otherwise it is
    ///   Agent Watch's own folder, which the instance lock has already created by the time
    ///   anything asks for this.
    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
    }

    /// The path to write into another program's configuration.
    @discardableResult
    func refresh(forExecutableAt executable: URL) -> SenderPath {
        let target = Self.senderURL(besideExecutableAt: executable)
        guard let link = resolvedDirectoryURL()?.appendingPathComponent("AgentWatchSend") else {
            return .tiedToThisBuild(target.path)
        }
        // Xcode builds only the product its scheme runs, and the sender is a product of its
        // own — so a run from Xcode has an app with nothing beside it. Claiming the link for
        // a file that is not there would silence hooks that were working, while the installed
        // bundle's sender delivers to whichever copy holds the socket regardless of which
        // copy it belongs to. So a build without a sender leaves the link as it found it.
        guard FileManager.default.isExecutableFile(atPath: target.path) else {
            // Only when there is a link to leave. With neither, naming it would claim a path
            // that runs nothing outlives the build; the absent file is what explains itself.
            return FileManager.default.isExecutableFile(atPath: link.path)
                ? .stable(link.path)
                : .tiedToThisBuild(target.path)
        }
        // Built under a second name and moved onto the first, because a hook may run at any
        // moment and `rename` is the one way to swap a name without it ever being empty.
        // Deleting and re-creating leaves a window in which the path another program was told
        // to run does not exist.
        let staging = link.appendingPathExtension("new")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)
        } catch {
            // Fail open, as every monitoring failure here must. Naming a link that was not
            // made would write a path that runs nothing, and a hook running nothing looks
            // exactly like an idle machine.
            return .tiedToThisBuild(target.path)
        }
        guard rename(staging.path, link.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            return .tiedToThisBuild(target.path)
        }
        return .stable(link.path)
    }

    /// The answer as it already stands, without making or replacing anything.
    ///
    /// For the window that reports what Agent Watch has written into other programs.
    /// Describing a state is not the moment to change it, and that window rebuilds every
    /// time it is opened and after every action in it — so asking through `refresh` re-made
    /// the link on each of those.
    func current(forExecutableAt executable: URL) -> SenderPath {
        let target = Self.senderURL(besideExecutableAt: executable)
        guard
            let link = resolvedDirectoryURL()?.appendingPathComponent("AgentWatchSend"),
            FileManager.default.isExecutableFile(atPath: link.path)
        else {
            // Either there is nowhere to keep a link, or nothing is there yet. Both mean the
            // path another program would be told is this build's own — which is what
            // `refresh` would answer too, and the window must not promise more than that.
            return .tiedToThisBuild(target.path)
        }
        return .stable(link.path)
    }

    private func resolvedDirectoryURL() -> URL? {
        if let directoryURL {
            return directoryURL
        }
        return AgentWatchPaths.supportDirectory()
    }

    /// The sender belonging to a running Agent Watch: the file beside it.
    ///
    /// The same rule in both worlds — the copy `build-app.sh` ships into the bundle, and the
    /// build directory's own during development. Neither is more canonical: the sender only
    /// delivers an event to a socket, so nothing downstream cares which copy did it.
    private static func senderURL(besideExecutableAt executable: URL) -> URL {
        executable.deletingLastPathComponent().appendingPathComponent("AgentWatchSend")
    }
}
