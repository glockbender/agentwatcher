import AgentWatchCore
import Darwin
import Foundation

#if AGENT_WATCH_DEBUG_CAPTURE

    /// The opt-in switch shared by the debug app and its short-lived hook senders.
    ///
    /// The timestamp rather than a process-local boolean is intentional: senders are launched
    /// independently, so expiry must still work after the AppKit process exits.
    public enum DebugHookCaptureControl {
        public static let defaultDuration: TimeInterval = 30 * 60

        /// The environment variable that moves the whole capture — switch, lock and segments —
        /// somewhere else.
        ///
        /// It exists so a test can drive the real path: hook process, spawned recorder, file on
        /// disk. Every unit test here calls the recorder directly, and that is exactly how a
        /// launcher that never once started went unnoticed. Debug-only, like everything in
        /// this file; a release build has no such control.
        public static let directoryOverrideVariable = "AGENT_WATCH_DEBUG_CAPTURE_DIR"

        public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
            if let override = ProcessInfo.processInfo.environment[directoryOverrideVariable],
                !override.isEmpty
            {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            guard let applicationSupport = AgentWatchPaths.applicationSupportDirectory(fileManager: fileManager)
            else {
                return nil
            }
            return AgentWatchPaths.supportDirectory(inApplicationSupport: applicationSupport)
                .appendingPathComponent("debug-hook-capture", isDirectory: true)
        }

        public static func enable(
            now: Date = .now,
            duration: TimeInterval = defaultDuration,
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Bool {
            guard
                duration > 0,
                let directoryURL = directoryURL ?? defaultDirectoryURL(fileManager: fileManager),
                ensureDirectory(directoryURL, fileManager: fileManager)
            else {
                return false
            }

            let configuration = Configuration(expiresAt: now.addingTimeInterval(duration))
            guard let data = try? JSONEncoder().encode(configuration) else {
                return false
            }
            let url = configurationURL(in: directoryURL)
            guard isNotSymbolicLink(url, fileManager: fileManager) else {
                return false
            }
            do {
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch {
                return false
            }
        }

        public static func disable(
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) {
            guard let directoryURL = directoryURL ?? defaultDirectoryURL(fileManager: fileManager) else {
                return
            }
            try? fileManager.removeItem(at: configurationURL(in: directoryURL))
        }

        /// Every file the capture has written, by name rather than by listing the folder:
        /// these are the only files this app put there, and a folder scan would offer to
        /// delete whatever else somebody had left in it.
        static func recordingURLs(in directoryURL: URL) -> [URL] {
            [DebugHookPayloadRecorder.currentSegmentURL(in: directoryURL)]
                + (1..<DebugHookPayloadRecorder.segmentCount).map {
                    DebugHookPayloadRecorder.segmentURL($0, in: directoryURL)
                }
        }

        /// How many bytes of original payload are on disk right now.
        ///
        /// Worth having as a number rather than a yes/no: what makes this data uncomfortable
        /// is not that it exists but how much of somebody's work it describes, and a menu
        /// that says "1.4 MB" answers a question "recorded payloads present" does not.
        public static func recordedByteCount(
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Int {
            guard let directoryURL = directoryURL ?? defaultDirectoryURL(fileManager: fileManager) else {
                return 0
            }
            return recordingURLs(in: directoryURL).reduce(0) { total, url in
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                    return total
                }
                return total + Int(info.st_size)
            }
        }

        /// Removes what was recorded, and only that.
        ///
        /// Kept apart from `disable` on purpose. Stopping a recording is what a person does
        /// in order to read it, so folding the deletion into the stop would throw away the
        /// evidence at the moment it became useful. The expiry is a limit on recording; this
        /// is the limit on keeping, and only a person can decide when that one is reached.
        public static func deleteRecordings(
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) {
            guard let directoryURL = directoryURL ?? defaultDirectoryURL(fileManager: fileManager) else {
                return
            }
            for url in recordingURLs(in: directoryURL) {
                _ = unlink(url.path)
            }
        }

        public static func expiry(
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Date? {
            guard
                let directoryURL = directoryURL ?? defaultDirectoryURL(fileManager: fileManager),
                let data = try? Data(contentsOf: configurationURL(in: directoryURL)),
                let configuration = try? JSONDecoder().decode(Configuration.self, from: data)
            else {
                return nil
            }
            return configuration.expiresAt
        }

        public static func isEnabled(
            now: Date = .now,
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Bool {
            guard let expiry = expiry(directoryURL: directoryURL, fileManager: fileManager) else {
                return false
            }
            return expiry > now
        }

        private struct Configuration: Codable {
            let expiresAt: Date
        }

        fileprivate static func ensureDirectory(_ directoryURL: URL, fileManager: FileManager) -> Bool {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
                var info = stat()
                return lstat(directoryURL.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            } catch {
                return false
            }
        }

        private static func configurationURL(in directoryURL: URL) -> URL {
            directoryURL.appendingPathComponent("capture-state.json", isDirectory: false)
        }

        private static func isNotSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
            guard fileManager.fileExists(atPath: url.path) else {
                return true
            }
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) != S_IFLNK
        }
    }

    /// Writes raw payloads only while the debug-only control is active.
    ///
    /// Five fixed-size segments make the hard storage budget structural: rotation drops an old
    /// segment before a new one can be created, so even a process crash cannot exceed the cap.
    public enum DebugHookPayloadRecorder {
        public static let maximumTotalByteCount = 10 * 1_024 * 1_024
        static let segmentCount = 5
        static let segmentByteCount = maximumTotalByteCount / segmentCount

        @discardableResult
        public static func record(
            source: AgentSource,
            declaredEvent: String,
            rawPayload: Data,
            decodedPayload: JSONValue,
            now: Date = .now,
            directoryURL: URL? = nil,
            fileManager: FileManager = .default
        ) -> Bool {
            guard
                let directoryURL = directoryURL
                    ?? DebugHookCaptureControl.defaultDirectoryURL(fileManager: fileManager),
                DebugHookCaptureControl.isEnabled(now: now, directoryURL: directoryURL, fileManager: fileManager),
                DebugHookCaptureControl.ensureDirectory(directoryURL, fileManager: fileManager),
                let line = makeLine(
                    source: source,
                    declaredEvent: declaredEvent,
                    rawPayload: rawPayload,
                    decodedPayload: decodedPayload,
                    capturedAt: now
                ),
                line.count <= segmentByteCount
            else {
                return false
            }

            do {
                let lock = try CaptureLock(in: directoryURL)
                defer { lock.release() }
                return try append(line, in: directoryURL)
            } catch {
                // Diagnostic capture must never delay or break a hook.
                return false
            }
        }

        private static func makeLine(
            source: AgentSource,
            declaredEvent: String,
            rawPayload: Data,
            decodedPayload: JSONValue,
            capturedAt: Date
        ) -> Data? {
            let header = Header(
                capturedAt: capturedAt,
                source: source,
                declaredEvent: declaredEvent,
                sessionIDLabel: sessionIDLabel(in: decodedPayload, declaredEvent: declaredEvent)
            )
            // The payload goes in byte for byte, so a newline inside it would end the record
            // early and leave the remainder as a second line that parses as nothing. A hook
            // whose payload ends in a newline is the ordinary case — the documented example
            // does it — so the outer whitespace is trimmed, which changes no JSON value.
            //
            // A newline still left inside means pretty-printed input, and that record is
            // dropped rather than mangled. Re-encoding it from the decoded value would keep
            // the record at the cost of the two things a raw capture is kept for: exact
            // numbers and repeated keys.
            let payload = trimmingOuterWhitespace(rawPayload)
            guard !payload.isEmpty, !payload.contains(UInt8(ascii: "\n")) else {
                return nil
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(header), line.last == UInt8(ascii: "}") else {
                return nil
            }
            line.removeLast()
            line.append(contentsOf: #","payload":"#.utf8)
            line.append(payload)
            line.append(UInt8(ascii: "}"))
            line.append(UInt8(ascii: "\n"))
            return line
        }

        private static func trimmingOuterWhitespace(_ payload: Data) -> Data {
            let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
            guard
                let first = payload.firstIndex(where: { !whitespace.contains($0) }),
                let last = payload.lastIndex(where: { !whitespace.contains($0) })
            else {
                return Data()
            }
            return Data(payload[first...last])
        }

        private static func sessionIDLabel(in payload: JSONValue, declaredEvent: String) -> String? {
            guard
                let redacted = try? HookCaptureRedactor.redact(declaredEvent: declaredEvent, payload: payload),
                case let .object(fields) = redacted.payload,
                case let .string(label)? = fields["session_id"]
            else {
                return nil
            }
            return label
        }

        static func append(
            _ line: Data,
            in directoryURL: URL,
            writeData: (Data, Int32) throws -> Void = write
        ) throws -> Bool {
            var descriptor = try openSegment(currentSegmentURL(in: directoryURL))
            defer { close(descriptor) }

            let size = try fileSize(of: descriptor)
            if size + Int64(line.count) > Int64(segmentByteCount) {
                close(descriptor)
                descriptor = -1
                try rotateSegments(in: directoryURL)
                descriptor = try openSegment(currentSegmentURL(in: directoryURL))
            }

            let initialOffset = try fileSize(of: descriptor)
            do {
                try writeData(line, descriptor)
            } catch {
                guard ftruncate(descriptor, initialOffset) == 0 else {
                    throw RecorderError.failedToRollback
                }
                throw error
            }
            return true
        }

        private static func rotateSegments(in directoryURL: URL) throws {
            try removeIfPresent(segmentURL(4, in: directoryURL))
            for index in stride(from: 3, through: 1, by: -1) {
                try renameIfPresent(segmentURL(index, in: directoryURL), to: segmentURL(index + 1, in: directoryURL))
            }
            try renameIfPresent(currentSegmentURL(in: directoryURL), to: segmentURL(1, in: directoryURL))
        }

        static func currentSegmentURL(in directoryURL: URL) -> URL {
            directoryURL.appendingPathComponent("hook-events.current.jsonl", isDirectory: false)
        }

        static func segmentURL(_ index: Int, in directoryURL: URL) -> URL {
            directoryURL.appendingPathComponent("hook-events.\(index).jsonl", isDirectory: false)
        }

        private static func openSegment(_ url: URL) throws -> Int32 {
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw RecorderError.failedToOpen
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                throw RecorderError.invalidSegment
            }
            _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
            return descriptor
        }

        private static func fileSize(of descriptor: Int32) throws -> Int64 {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw RecorderError.failedToReadSize
            }
            return info.st_size
        }

        private static func write(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                guard let start = bytes.baseAddress else {
                    return
                }
                var pointer = start.assumingMemoryBound(to: UInt8.self)
                var remaining = bytes.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written > 0 {
                        pointer = pointer.advanced(by: written)
                        remaining -= written
                        continue
                    }
                    if written < 0, errno == EINTR {
                        continue
                    }
                    throw RecorderError.incompleteWrite
                }
            }
        }

        private static func removeIfPresent(_ url: URL) throws {
            guard unlink(url.path) != 0, errno != ENOENT else {
                return
            }
            throw RecorderError.failedToRotate
        }

        private static func renameIfPresent(_ source: URL, to destination: URL) throws {
            guard rename(source.path, destination.path) != 0, errno != ENOENT else {
                return
            }
            throw RecorderError.failedToRotate
        }

        private struct Header: Encodable {
            let capturedAt: Date
            let source: AgentSource
            let declaredEvent: String
            let sessionIDLabel: String?

            enum CodingKeys: String, CodingKey {
                case capturedAt = "captured_at"
                case source
                case declaredEvent = "declared_event"
                case sessionIDLabel = "session_id_label"
            }
        }

        private enum RecorderError: Error {
            case failedToOpen
            case failedToReadSize
            case failedToRollback
            case failedToRotate
            case incompleteWrite
            case invalidSegment
        }
    }

    private struct CaptureLock {
        private let descriptor: Int32

        init(in directoryURL: URL) throws {
            let url = directoryURL.appendingPathComponent(".hook-events.lock", isDirectory: false)
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw LockError.failedToOpen
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor)
                throw LockError.invalidFile
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw LockError.busy
            }
            self.descriptor = descriptor
        }

        func release() {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        private enum LockError: Error {
            case busy
            case failedToOpen
            case invalidFile
        }
    }

#endif
