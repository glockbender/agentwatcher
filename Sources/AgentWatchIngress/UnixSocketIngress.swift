import AgentWatchCore
import Darwin
import Foundation

public enum UnixSocketIngressError: Error, Equatable, Sendable {
    case invalidSocketPath
    case socketCreationFailed
    case existingPathIsNotSocket
    case bindFailed
    case listenFailed
    case messageDecodingFailed
    case permissionChangeFailed
    case messageTooLarge
    case malformedMessage
    case readTimedOut
}

public final class UnixSocketIngress: @unchecked Sendable {
    public static let maximumMessageByteCount = HookCaptureRedactor.maximumInputByteCount + 65_536

    /// Called once per connection, in the order the connections arrived.
    ///
    /// The ordering is part of this interface, not an accident of the implementation: what
    /// arrives here are lifecycle transitions, and a caller that reorders them undoes the
    /// guarantee. A handler that hands the work to another queue has to keep it — an
    /// unstructured `Task` does not, `DispatchQueue.main.async` does.
    public typealias Handler = @Sendable (Result<HookIngressRequest, UnixSocketIngressError>) -> Void

    private let socketPath: String
    private let handler: Handler
    /// How long one connection may take to deliver its message before it is abandoned.
    private let readTimeoutMilliseconds: Int32
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "AgentWatch.UnixSocketIngress.accept")
    /// Serial, and that is the point rather than an oversight.
    ///
    /// What crosses this socket are lifecycle transitions, so their order is the whole of
    /// their meaning — a call that ends before it starts leaves a row claiming work nothing
    /// is doing. Read side by side, two connections finish in whatever order their reads
    /// finish, which is not the order they arrived in; a message held one byte short of
    /// complete let a later one overtake it, reproducibly.
    ///
    /// Nothing is lost by serialising. Each message is one short line, the read has a 200 ms
    /// deadline of its own, and a hook costs three-quarters of a second to launch — so there
    /// is no throughput here for concurrency to win back.
    private let connectionQueue = DispatchQueue(label: "AgentWatch.UnixSocketIngress.connection")
    private var listenerDescriptor: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var ownedSocket: SocketIdentity?

    /// The name can be replaced while this listener is alive. Cleanup owns the inode it
    /// created, not whatever happens to occupy that name later.
    private struct SocketIdentity {
        let device: dev_t
        let inode: ino_t

        init?(at path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else {
                return nil
            }
            device = info.st_dev
            inode = info.st_ino
        }

        func matches(_ other: SocketIdentity) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    /// - Parameter readTimeoutMilliseconds: 200 in the app. A test that holds a connection
    ///   open on purpose gives itself room here, so that a slow machine does not turn its
    ///   pause into an abandoned connection — the CI machine did, and the ordering test failed
    ///   with the first event missing.
    public init(socketPath: String, readTimeoutMilliseconds: Int32 = 200, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard listenerDescriptor == -1 else {
            return
        }

        try removeExistingSocket()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketIngressError.socketCreationFailed
        }

        do {
            try bind(descriptor)
            ownedSocket = SocketIdentity(at: socketPath)
            guard ownedSocket != nil else {
                throw UnixSocketIngressError.bindFailed
            }
            guard listen(descriptor, SOMAXCONN) == 0 else {
                throw UnixSocketIngressError.listenFailed
            }
            guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
                throw UnixSocketIngressError.permissionChangeFailed
            }
        } catch {
            close(descriptor)
            removeOwnedSocket()
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {}
        listenerDescriptor = descriptor
        listenerSource = source
        source.resume()
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        let descriptor = listenerDescriptor
        let source = listenerSource
        listenerDescriptor = -1
        listenerSource = nil

        source?.cancel()
        if descriptor >= 0 {
            close(descriptor)
        }
        removeOwnedSocket()
    }

    /// Called only while holding `stateLock`, including failure during startup.
    private func removeOwnedSocket() {
        defer { ownedSocket = nil }
        guard let ownedSocket, let current = SocketIdentity(at: socketPath), ownedSocket.matches(current) else {
            return
        }
        _ = unlink(socketPath)
    }

    private func acceptConnection() {
        stateLock.lock()
        let descriptor = listenerDescriptor
        stateLock.unlock()
        guard descriptor >= 0 else {
            return
        }

        let connectionDescriptor = accept(descriptor, nil, nil)
        guard connectionDescriptor >= 0 else {
            return
        }

        connectionQueue.async { [weak self] in
            defer { close(connectionDescriptor) }
            self?.readAndHandleConnection(connectionDescriptor)
        }
    }

    private func readAndHandleConnection(_ descriptor: Int32) {
        do {
            let request = try Self.readRequest(from: descriptor, timeoutMilliseconds: readTimeoutMilliseconds)
            handler(.success(request))
        } catch let error as UnixSocketIngressError {
            handler(.failure(error))
        } catch {
            handler(.failure(.malformedMessage))
        }
    }

    private func bind(_ descriptor: Int32) throws {
        guard var address = PosixSocket.makeAddress(path: socketPath) else {
            throw UnixSocketIngressError.invalidSocketPath
        }
        let result = PosixSocket.withSockaddr(&address) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard result == 0 else {
            throw UnixSocketIngressError.bindFailed
        }
    }

    private func removeExistingSocket() throws {
        var fileInfo = stat()
        if lstat(socketPath, &fileInfo) == 0 {
            guard (fileInfo.st_mode & S_IFMT) == S_IFSOCK else {
                throw UnixSocketIngressError.existingPathIsNotSocket
            }
            guard unlink(socketPath) == 0 else {
                throw UnixSocketIngressError.bindFailed
            }
            return
        }

        guard errno == ENOENT else {
            throw UnixSocketIngressError.bindFailed
        }
    }

    private static func readRequest(from descriptor: Int32, timeoutMilliseconds: Int32) throws -> HookIngressRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let deadline = PosixSocket.deadline(afterMilliseconds: timeoutMilliseconds)

        while true {
            guard PosixSocket.waitForEvents(Int16(POLLIN), on: descriptor, until: deadline) != nil else {
                throw UnixSocketIngressError.readTimedOut
            }

            let byteCount = buffer.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            if byteCount > 0 {
                buffer.withUnsafeBytes { buffer in
                    data.append(contentsOf: buffer.prefix(byteCount))
                }
                if let lineEnd = data.firstIndex(of: 0x0A) {
                    data = data.prefix(upTo: lineEnd)
                    break
                }
                guard data.count <= maximumMessageByteCount else {
                    throw UnixSocketIngressError.messageTooLarge
                }
                continue
            }
            if byteCount == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw UnixSocketIngressError.readTimedOut
            }
            throw UnixSocketIngressError.malformedMessage
        }

        guard !data.isEmpty, data.count <= maximumMessageByteCount else {
            throw UnixSocketIngressError.malformedMessage
        }
        do {
            return try JSONDecoder().decode(HookIngressRequest.self, from: data)
        } catch {
            throw UnixSocketIngressError.messageDecodingFailed
        }
    }
}
