import AgentWatchCore
import Darwin
import Foundation

/// Keeps one Agent Watch running at a time.
///
/// A hook delivers to one socket name, so a second instance would either take that name from
/// the first or listen where no hook looks. Neither is a state worth having, and the second
/// one is invisible: the extra window fills with nothing and says nothing about why.
final class SingleInstanceCoordinator {
    private let directoryURL: URL?
    private var lockDescriptor: Int32?

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL
    }

    deinit {
        releaseLock()
    }

    /// Whether this process is the one that may run. A second one is expected to hand its
    /// launch to the first and exit.
    func mayLaunch() -> Bool {
        acquireLock()
    }

    func socketURL() -> URL? {
        preparedDirectoryURL().map { AgentWatchPaths.socketURL(inDirectory: $0) }
    }

    private func acquireLock() -> Bool {
        if lockDescriptor != nil {
            return true
        }

        guard let lockURL = preparedDirectoryURL()?.appendingPathComponent("instance.lock") else {
            return false
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    private func releaseLock() {
        guard let lockDescriptor else {
            return
        }

        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        self.lockDescriptor = nil
    }

    private func preparedDirectoryURL() -> URL? {
        if let directoryURL {
            return directoryURL
        }
        guard let applicationSupport = AgentWatchPaths.applicationSupportDirectory() else {
            return nil
        }
        let directoryURL = AgentWatchPaths.supportDirectory(inApplicationSupport: applicationSupport)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return directoryURL
    }
}
