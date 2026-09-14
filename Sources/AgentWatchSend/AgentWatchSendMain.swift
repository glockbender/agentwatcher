import AgentWatchCore
import AgentWatchSender
import Darwin
import Foundation

#if AGENT_WATCH_DEBUG_CAPTURE
    // Darwin exposes shm_open as a C variadic function; Swift cannot import that form directly.
    @_silgen_name("shm_open")
    private func openSharedMemory(_ name: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32
#endif

@main
enum AgentWatchSendMain {
    static func main() {
        guard let options = Options(arguments: Array(CommandLine.arguments.dropFirst())) else {
            return
        }

        #if AGENT_WATCH_DEBUG_CAPTURE
            let input =
                options.isRawCaptureProcess
                ? readRawCaptureInput(options)
                : readInput(until: deadline(after: options.timeoutMilliseconds))
        #else
            let input = readInput(until: deadline(after: options.timeoutMilliseconds))
        #endif

        guard
            let input,
            let payload = try? JSONDecoder().decode(JSONValue.self, from: input),
            case .object = payload
        else {
            return
        }

        #if AGENT_WATCH_DEBUG_CAPTURE
            if options.isRawCaptureProcess {
                _ = DebugHookPayloadRecorder.record(
                    source: options.source,
                    declaredEvent: options.event,
                    rawPayload: input,
                    decodedPayload: payload
                )
                return
            }
        #endif

        guard let request = makeRequest(options: options, payload: payload) else {
            return
        }
        if let socketPath = options.socketPath ?? HookEventSender.defaultSocketPath() {
            _ = try? HookEventSender.send(
                request,
                to: socketPath,
                timeoutMilliseconds: options.timeoutMilliseconds
            )
        }

        // Last, after the event is on its way. Diagnostics may cost the hook nothing it did
        // not already owe: reading the switch, copying the payload and starting a second
        // process are all work the agent would otherwise be waiting through.
        #if AGENT_WATCH_DEBUG_CAPTURE
            if DebugHookCaptureControl.isEnabled() {
                DebugHookCaptureLauncher.start(
                    source: options.source,
                    declaredEvent: options.event,
                    rawPayload: input
                )
            }
        #endif
    }

    private static func deadline(after timeoutMilliseconds: Int32) -> UInt64 {
        PosixSocket.deadline(afterMilliseconds: timeoutMilliseconds)
    }

    private static func readInput(until deadline: UInt64) -> Data? {
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return nil
        }

        var input = Data()
        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let byteCount = buffer.withUnsafeMutableBytes { buffer in
                read(STDIN_FILENO, buffer.baseAddress, chunkSize)
            }
            if byteCount > 0 {
                input.append(buffer, count: byteCount)
                if input.count > HookCaptureRedactor.maximumInputByteCount {
                    return nil
                }
                continue
            }
            if byteCount == 0 {
                return input
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                return nil
            }
            guard waitForInput(STDIN_FILENO, deadline: deadline) else {
                return nil
            }
        }
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        private static func readRawCaptureInput(_ options: Options) -> Data? {
            guard
                let descriptor = options.rawCaptureDescriptor,
                let length = options.rawCaptureLength,
                length > 0,
                length <= HookCaptureRedactor.maximumInputByteCount
            else {
                return nil
            }
            defer { close(descriptor) }

            // Big enough, not exactly the size. A shared-memory object is rounded up to a
            // whole page, so 61 bytes of payload arrive in an object of 16384 and an equality
            // check refuses every payload there has ever been. What the mapping below needs
            // is room for `length`, and the parent wrote exactly that many bytes at the
            // front; the rest of the page is the zeroes the kernel put there.
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= length else {
                return nil
            }
            guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED
            else {
                return nil
            }
            defer { _ = munmap(mapping, length) }
            return Data(bytes: mapping, count: length)
        }
    #endif

    private static func makeRequest(options: Options, payload: JSONValue) -> RedactedHookIngressRequest? {
        // First, before the transcript is read for a description: a tool call made inside a
        // subagent is not the session's own work, and every one of them would land on the
        // session's row and stay there for ever. `SubagentToolCall` carries the measurements.
        // This is the only place that can tell — the path it judges by never leaves here.
        guard !SubagentToolCall.fired(declaredEvent: options.event, payload: payload) else {
            return nil
        }

        let description: SessionDescription?
        if options.source == .codex {
            let codexSession = SessionDescriptionResolver.resolveCodexSession(payload: payload)
            // Codex Desktop also invokes configured hooks for an internal service session.
            // Its ID never becomes a user thread in `session_index.jsonl`; withholding it
            // here keeps a service turn from entering deterministic session state at all.
            guard codexSession.isIndexed else {
                return nil
            }
            description = codexSession.description
        } else {
            description = SessionDescriptionResolver.resolve(source: options.source, payload: payload)
        }
        return RedactedHookIngressRequest.make(
            source: options.source,
            declaredEvent: options.event,
            payload: payload,
            agentProcessID: options.source == .claude ? AgentProcessLocator.currentClaudeProcessID() : nil,
            clientKind: AgentProcessLocator.currentClientKind(for: options.source),
            description: description,
            // On every hook, not only the start: the app may not have been running when the
            // copy started, and the first event it hears has to be the one that says so.
            forkedFromSessionID: options.source == .claude
                ? sessionID(in: payload).flatMap(AgentProcessLocator.currentForkedFromSessionID(forSessionID:))
                : nil
        )
    }

    /// The session the hook is about, raw, before anything is redacted. Read here only to be
    /// compared with the process's own arguments; it leaves this process redacted like every
    /// other identifier.
    private static func sessionID(in payload: JSONValue) -> String? {
        guard case let .object(fields) = payload, case let .string(id)? = fields["session_id"] else {
            return nil
        }
        return id
    }

    /// A closed input counts as ready: the last `read` then returns zero and ends the loop.
    private static func waitForInput(_ descriptor: Int32, deadline: UInt64) -> Bool {
        guard let revents = PosixSocket.waitForEvents(Int16(POLLIN), on: descriptor, until: deadline) else {
            return false
        }
        return revents & Int16(POLLIN | POLLHUP) != 0
    }
}

private struct Options {
    let source: AgentSource
    let event: String
    let socketPath: String?
    let timeoutMilliseconds: Int32
    let isRawCaptureProcess: Bool
    #if AGENT_WATCH_DEBUG_CAPTURE
        let rawCaptureDescriptor: Int32?
        let rawCaptureLength: Int?
    #endif

    init?(arguments: [String]) {
        guard
            let values = CommandLineOptions.parse(arguments),
            let sourceValue = values["--source"],
            let source = AgentSource(rawValue: sourceValue),
            let event = values["--event"]
        else {
            return nil
        }

        self.source = source
        self.event = event
        socketPath = values["--socket"]
        isRawCaptureProcess = values["--raw-capture"] == "yes"
        #if AGENT_WATCH_DEBUG_CAPTURE
            if isRawCaptureProcess {
                guard
                    let descriptorValue = values["--raw-capture-fd"],
                    let descriptor = Int32(descriptorValue),
                    descriptor >= 0,
                    let lengthValue = values["--raw-capture-length"],
                    let length = Int(lengthValue),
                    length > 0,
                    length <= HookCaptureRedactor.maximumInputByteCount
                else {
                    return nil
                }
                rawCaptureDescriptor = descriptor
                rawCaptureLength = length
            } else {
                rawCaptureDescriptor = nil
                rawCaptureLength = nil
            }
        #endif
        if let timeoutValue = values["--timeout-ms"] {
            guard let timeout = Int32(timeoutValue), timeout > 0 else {
                return nil
            }
            timeoutMilliseconds = timeout
        } else {
            timeoutMilliseconds = HookEventSender.defaultTimeoutMilliseconds
        }
    }
}

#if AGENT_WATCH_DEBUG_CAPTURE
    /// Starts a separate best-effort recorder. The parent hands the bytes to the child via an
    /// unlinked shared-memory descriptor, keeping disk I/O out of the hook's delivery path.
    private enum DebugHookCaptureLauncher {
        private static let preferredChildDescriptor: Int32 = 100

        static func start(source: AgentSource, declaredEvent: String, rawPayload: Data) {
            guard !rawPayload.isEmpty else {
                return
            }
            // Darwin allows 31 characters for a shared-memory name, the leading slash
            // included — a quarter of what a path may be, and `shm_open` answers a longer one
            // with ENAMETOOLONG rather than truncating it. A full UUID took this to 55 and
            // failed every single time, silently, because the failure path here is a return.
            let sharedMemoryName = "/aw-dbg-\(UUID().uuidString.prefix(16))"
            let descriptor = sharedMemoryName.withCString {
                openSharedMemory($0, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                return
            }
            defer {
                close(descriptor)
                _ = shm_unlink(sharedMemoryName)
            }
            guard ftruncate(descriptor, off_t(rawPayload.count)) == 0 else {
                return
            }
            guard
                let mapping = mmap(
                    nil,
                    rawPayload.count,
                    PROT_READ | PROT_WRITE,
                    MAP_SHARED,
                    descriptor,
                    0
                ),
                mapping != MAP_FAILED
            else {
                return
            }
            defer { _ = munmap(mapping, rawPayload.count) }
            rawPayload.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else {
                    return
                }
                memcpy(mapping, source, rawPayload.count)
            }

            // `shm_open` may return a close-on-exec descriptor. Always duplicate it to a
            // different descriptor in the child, which clears that flag before exec.
            let childDescriptor =
                descriptor == preferredChildDescriptor
                ? preferredChildDescriptor + 1
                : preferredChildDescriptor
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                return
            }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard
                posix_spawn_file_actions_adddup2(&actions, descriptor, childDescriptor) == 0,
                posix_spawn_file_actions_addclose(&actions, descriptor) == 0
            else {
                return
            }

            let arguments = [
                CommandLine.arguments[0],
                "--source", source.rawValue,
                "--event", declaredEvent,
                "--raw-capture", "yes",
                "--raw-capture-fd", String(childDescriptor),
                "--raw-capture-length", String(rawPayload.count),
            ]
            var command = arguments.map { strdup($0) }
            defer { command.forEach { free($0) } }
            guard !command.contains(where: { $0 == nil }) else {
                return
            }
            command.append(nil)

            var processID: pid_t = 0
            let result = posix_spawnp(
                &processID,
                command[0],
                &actions,
                nil,
                &command,
                environ
            )
            _ = result
        }
    }
#endif
