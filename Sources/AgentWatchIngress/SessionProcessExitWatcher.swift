import Dispatch
import Foundation

/// Observes a small set of agent processes without polling and reports their exits by session ID.
public final class SessionProcessExitWatcher: @unchecked Sendable {
    public typealias Handler = (String) -> Void

    private struct WatchedProcess {
        let processID: Int32
        let source: DispatchSourceProcess
    }

    private let handler: Handler
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var watchedProcesses: [String: WatchedProcess] = [:]

    public init(queue: DispatchQueue = .main, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    deinit {
        lock.lock()
        let activeSources = watchedProcesses.values.map(\.source)
        watchedProcesses.removeAll()
        lock.unlock()
        activeSources.forEach { $0.cancel() }
    }

    public func watch(sessionID: String, processID: Int32) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid_t(processID),
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleExit(sessionID: sessionID, processID: processID)
        }

        lock.lock()
        let replaced = watchedProcesses.updateValue(
            WatchedProcess(processID: processID, source: source),
            forKey: sessionID
        )
        lock.unlock()

        replaced?.source.cancel()
        source.resume()
    }

    public func unwatch(sessionID: String) {
        lock.lock()
        let watchedProcess = watchedProcesses.removeValue(forKey: sessionID)
        lock.unlock()

        watchedProcess?.source.cancel()
    }

    private func handleExit(sessionID: String, processID: Int32) {
        lock.lock()
        guard watchedProcesses[sessionID]?.processID == processID else {
            lock.unlock()
            return
        }
        let watchedProcess = watchedProcesses.removeValue(forKey: sessionID)
        lock.unlock()

        watchedProcess?.source.cancel()
        handler(sessionID)
    }
}
