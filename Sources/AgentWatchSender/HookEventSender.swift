import AgentWatchCore
import Darwin
import Foundation

/// Sends one versioned hook event to the local Agent Watch socket.
///
/// This transport deliberately has no retry policy: hooks must remain fail-open
/// and never wait behind a temporarily unavailable desktop application.
public enum HookEventSender {
    public static let defaultTimeoutMilliseconds: Int32 = 100

    public static func send(
        _ request: RedactedHookIngressRequest,
        to socketPath: String,
        timeoutMilliseconds: Int32 = defaultTimeoutMilliseconds
    ) throws {
        guard timeoutMilliseconds > 0 else {
            throw HookEventSenderError.invalidTimeout
        }

        var message = try JSONEncoder().encode(request.ingressRequest)
        message.append(0x0A)
        try send(message, to: socketPath, deadline: deadline(after: timeoutMilliseconds))
    }

    /// Where the running Agent Watch listens, or `nil` when nothing has created it.
    ///
    /// Which name counts is `AgentWatchPaths`' answer, not this file's. The app creates it and
    /// this looks for it from another target, in a process that lives under a second — and a
    /// disagreement between the two says nothing at all, because hooks are fail-open: no
    /// error, no log, just a widget that stays empty.
    public static func defaultSocketPath() -> String? {
        AgentWatchPaths.supportDirectory()
            .map { AgentWatchPaths.socketURL(inDirectory: $0).path }
    }

    fileprivate static func send(_ message: Data, to socketPath: String, deadline: UInt64) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HookEventSenderError.socketCreationFailed
        }
        defer { close(descriptor) }

        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw HookEventSenderError.socketConfigurationFailed
        }
        var suppressSIGPIPE: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &suppressSIGPIPE,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            throw HookEventSenderError.socketConfigurationFailed
        }

        guard var address = PosixSocket.makeAddress(path: socketPath) else {
            throw HookEventSenderError.invalidSocketPath
        }
        try PosixSocket.withSockaddr(&address) { address, length in
            let result = connect(descriptor, address, length)
            if result == 0 || errno == EISCONN {
                return
            }
            guard errno == EINPROGRESS else {
                throw HookEventSenderError.connectionFailed
            }
            try waitForWrite(descriptor, deadline: deadline)

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0,
                socketError == 0
            else {
                throw HookEventSenderError.connectionFailed
            }
        }

        try message.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw HookEventSenderError.writeFailed
            }

            var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var remaining = buffer.count
            while remaining > 0 {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw HookEventSenderError.timedOut
                }
                let written = write(descriptor, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw HookEventSenderError.writeFailed
                }
                try waitForWrite(descriptor, deadline: deadline)
            }
        }
        _ = shutdown(descriptor, SHUT_WR)
    }

    private static func deadline(after timeoutMilliseconds: Int32) -> UInt64 {
        PosixSocket.deadline(afterMilliseconds: timeoutMilliseconds)
    }

    private static func waitForWrite(_ descriptor: Int32, deadline: UInt64) throws {
        guard
            let revents = PosixSocket.waitForEvents(Int16(POLLOUT), on: descriptor, until: deadline),
            revents & Int16(POLLOUT) != 0
        else {
            throw HookEventSenderError.timedOut
        }
    }
}

/// Sends a bounded local request to reveal the primary Agent Watch widget.
/// Unlike hook delivery, this retries briefly because a second Xcode launch can
/// arrive while the first instance is still creating its socket.
public enum LocalControlSender {
    public static let startupRetryMilliseconds: Int32 = 500
    private static let retryIntervalMicroseconds: useconds_t = 25_000

    @discardableResult
    public static func requestRevealExistingInstance(
        to socketPath: String,
        onFirstFailure: (() -> Void)? = nil
    ) -> Bool {
        let request = LocalAgentWatchControl.revealExistingInstanceRequest()
        guard var message = try? JSONEncoder().encode(request) else {
            return false
        }
        message.append(0x0A)

        let deadline =
            DispatchTime.now().uptimeNanoseconds
            + UInt64(startupRetryMilliseconds) * 1_000_000
        var observedFailure = false
        repeat {
            if (try? HookEventSender.send(message, to: socketPath, deadline: deadline)) != nil {
                return true
            }
            if !observedFailure {
                observedFailure = true
                onFirstFailure?()
            }
            usleep(retryIntervalMicroseconds)
        } while DispatchTime.now().uptimeNanoseconds < deadline

        return false
    }
}

/// A request that has been redacted before it can enter the socket transport.
public struct RedactedHookIngressRequest: Sendable {
    fileprivate let ingressRequest: HookIngressRequest

    /// - Parameter forkedFromSessionID: the session this one was copied from, raw, as the
    ///   process's own arguments name it. Put into the payload rather than beside it so the
    ///   redactor labels it exactly as it labels `session_id` — the only way it can ever be
    ///   matched against the original's row on the other side.
    public static func make(
        source: AgentSource,
        declaredEvent: String,
        payload: JSONValue,
        agentProcessID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        description: SessionDescription? = nil,
        forkedFromSessionID: String? = nil
    ) -> RedactedHookIngressRequest? {
        var payload = payload
        if let forkedFromSessionID, case var .object(fields) = payload {
            fields["forked_from_session_id"] = .string(forkedFromSessionID)
            payload = .object(fields)
        }
        guard
            let captured = try? HookCaptureRedactor.redact(
                declaredEvent: declaredEvent,
                payload: payload
            )
        else {
            return nil
        }

        return RedactedHookIngressRequest(
            ingressRequest: HookIngressRequest(
                source: source,
                declaredEvent: captured.declaredEvent,
                payload: captured.payload,
                agentProcessID: agentProcessID,
                clientKind: clientKind,
                description: description,
                toolRunsInBackground: runsInBackground(in: payload)
            )
        )
    }

    /// Reads `tool_input.run_in_background` off the payload the hook was given.
    ///
    /// Here rather than in the redactor because the redactor replaces `tool_input` whole —
    /// it holds the shell command — and one boolean is not worth opening that door. Only a
    /// real boolean counts: a string `"true"` is a payload shape nobody promised, and
    /// guessing at it would be inventing a fact.
    private static func runsInBackground(in payload: JSONValue) -> Bool? {
        guard
            case let .object(fields) = payload,
            case let .object(toolInput)? = fields["tool_input"] ?? fields["toolInput"],
            case let .bool(value)? = toolInput["run_in_background"] ?? toolInput["runInBackground"]
        else {
            return nil
        }
        return value
    }
}

public enum HookEventSenderError: Error, Equatable, Sendable {
    case connectionFailed
    case invalidSocketPath
    case invalidTimeout
    case socketConfigurationFailed
    case socketCreationFailed
    case timedOut
    case writeFailed
}
