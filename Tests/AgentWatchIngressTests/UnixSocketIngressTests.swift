import AgentWatchCore
import AgentWatchIngress
import AgentWatchSender
import Darwin
import Foundation
import XCTest

final class UnixSocketIngressTests: XCTestCase {
    func testReceivesOneLineDelimitedIngressRequest() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "ingress request")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let request = HookIngressRequest(
            source: .codex,
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string("session")])
        )
        try send(request, to: socketPath)

        wait(for: [received], timeout: 1)
        XCTAssertEqual(results.snapshot(), [.success(request)])
    }

    func testSenderExitsQuietlyWhenSocketIsUnavailable() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sender = try runSender(
            input: Data("{\"session_id\":\"session\"}".utf8),
            arguments: [
                "--source", "codex",
                "--event", "SessionStart",
                "--socket", directoryURL.appendingPathComponent("missing.sock").path,
            ]
        )

        XCTAssertEqual(sender.status, 0)
        XCTAssertTrue(sender.standardOutput.isEmpty)
        XCTAssertTrue(sender.standardError.isEmpty)
    }

    func testSenderDeliversEventToIngress() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "sender event arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let request = try XCTUnwrap(
            RedactedHookIngressRequest.make(
                source: .claude,
                declaredEvent: "PostToolUse",
                payload: .object(["session_id": .string("session")])
            ))
        try HookEventSender.send(request, to: socketPath)

        wait(for: [received], timeout: 1)
        let result = try XCTUnwrap(results.snapshot().first)
        let receivedRequest = try result.get()
        XCTAssertEqual(receivedRequest.source, .claude)
        XCTAssertEqual(receivedRequest.declaredEvent, "PostToolUse")
        XCTAssertNotEqual(receivedRequest.payload, .object(["session_id": .string("session")]))
    }

    /// The original a fork was copied from travels inside the payload, so that it is
    /// redacted on the way out exactly as `session_id` is and lands on the label the original
    /// row already carries. It is put there by the sender, not read from the hook — no hook
    /// field names it.
    func testTheSenderPutsTheContinuedSessionIntoThePayloadRedacted() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "fork event arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let original = "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"
        let request = try XCTUnwrap(
            RedactedHookIngressRequest.make(
                source: .claude,
                declaredEvent: "SessionStart",
                payload: .object(["session_id": .string("b95a16c1-8449-41f9-8487-5b3e0ad5e052")]),
                forkedFromSessionID: original
            ))
        try HookEventSender.send(request, to: socketPath)

        wait(for: [received], timeout: 1)
        let receivedRequest = try XCTUnwrap(results.snapshot().first).get()
        guard case let .object(fields) = receivedRequest.payload else {
            return XCTFail("Expected an object payload")
        }
        let onceRedacted = try HookCaptureRedactor.redact(
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string(original)])
        )
        guard case let .object(expected) = onceRedacted.payload else {
            return XCTFail("Expected an object payload")
        }
        XCTAssertEqual(fields["forked_from_session_id"], expected["session_id"], "labelled exactly like a session id")
        XCTAssertNotEqual(fields["forked_from_session_id"], .string(original), "never raw across the socket")
    }

    /// What `Stop` says is still running travels beside the payload, not inside it.
    ///
    /// `background_tasks` is already a sensitive key and stays one here: the entry holds the
    /// command line, and nothing in the row wants it. So the sender lifts out the one thing
    /// the row does want — the kind of each task — exactly as it lifts out
    /// `run_in_background`, and the entries are redacted on the way as they always were.
    func testTheSenderCarriesTheKindsStopReportedAndNotTheCommands() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "stop event arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let request = try XCTUnwrap(
            RedactedHookIngressRequest.make(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object([
                    "session_id": .string("session"),
                    "background_tasks": .array([
                        .object([
                            "id": .string("b2x71w2yx"),
                            "type": .string("shell"),
                            "status": .string("running"),
                            "command": .string("python3 review.py --mr 67 wait"),
                        ])
                    ]),
                ])
            ))
        try HookEventSender.send(request, to: socketPath)

        wait(for: [received], timeout: 1)
        let receivedRequest = try XCTUnwrap(results.snapshot().first).get()
        XCTAssertEqual(receivedRequest.backgroundWork, [.shell])
        guard case let .object(fields) = receivedRequest.payload else {
            return XCTFail("Expected an object payload")
        }
        XCTAssertEqual(
            fields["background_tasks"],
            .string("<redacted>"),
            "the entries themselves never cross the socket — the redactor already holds that door shut"
        )
    }

    func testLocalControlSenderDeliversRevealRequestToIngress() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "reveal request arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        XCTAssertTrue(LocalControlSender.requestRevealExistingInstance(to: socketPath))

        wait(for: [received], timeout: 1)
        let request = try XCTUnwrap(try results.snapshot().first?.get())
        XCTAssertTrue(LocalAgentWatchControl.isRevealExistingInstance(request))
    }

    func testLocalControlSenderRetriesUntilThePrimarySocketIsReady() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()

        let firstFailure = expectation(description: "first connection attempt fails")
        let senderCompleted = expectation(description: "control sender completes")
        let received = expectation(description: "retried reveal request arrives")
        let delivery = ControlDeliveryResult()
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        defer { ingress.stop() }

        DispatchQueue.global().async {
            delivery.set(
                LocalControlSender.requestRevealExistingInstance(
                    to: socketPath,
                    onFirstFailure: {
                        firstFailure.fulfill()
                    }
                ))
            senderCompleted.fulfill()
        }

        wait(for: [firstFailure], timeout: 1)
        // Derived from the retry budget rather than fixed: the listener has to appear while
        // the sender is still trying, and half of whatever that budget is says so. A number
        // written here instead would have to be changed by hand whenever the budget is
        // retuned, which is how a test comes to assert a tuning constant.
        Thread.sleep(forTimeInterval: Double(LocalControlSender.startupRetryMilliseconds) / 2_000)
        try ingress.start()

        wait(for: [senderCompleted], timeout: 1)
        XCTAssertTrue(delivery.value)
        wait(for: [received], timeout: 1)
        let request = try XCTUnwrap(try results.snapshot().first?.get())
        XCTAssertTrue(LocalAgentWatchControl.isRevealExistingInstance(request))
    }

    func testExecutableRedactsPayloadBeforeSendingItToIngress() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "redacted sender event arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let sender = try runSender(
            input: Data("{\"session_id\":\"session-secret\",\"prompt\":\"private prompt\"}".utf8),
            arguments: [
                "--source", "claude",
                "--event", "UserPromptSubmit",
                "--socket", socketPath,
            ]
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [received], timeout: 1)
        let result = try XCTUnwrap(results.snapshot().first)
        let request = try result.get()
        guard case let .object(fields) = request.payload else {
            return XCTFail("Expected a redacted JSON object")
        }
        XCTAssertNotEqual(fields["session_id"], .string("session-secret"))
        XCTAssertEqual(fields["prompt"], .string("<redacted>"))
    }

    /// A subagent's tool call reaches the app, and says whose it is.
    ///
    /// Through the real executable, with the payload shaped as Claude Code 2.1.272 actually
    /// sends it: `transcript_path` is the **parent's**, identical to the main thread's, and
    /// the subagent is named only by `agent_id`. A filter that judged by the path used to
    /// stand here and recognised nobody; this is what has to keep working now it is gone —
    /// the call is what a permission dialog is about, so dropping it would leave the dialog
    /// with nothing to point at.
    func testExecutableDeliversASubagentsCallAndNamesTheSubagent() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "the subagent's call arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let payload = """
            {"session_id":"session","agent_id":"agent-a","agent_type":"general-purpose",\
            "tool_use_id":"tool","tool_name":"Bash",\
            "transcript_path":"/tmp/projects/p/session.jsonl"}
            """
        let sender = try runSender(
            input: Data(payload.utf8),
            arguments: [
                "--source", "claude",
                "--event", "PreToolUse",
                "--socket", socketPath,
            ]
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [received], timeout: 1)
        let request = try results.snapshot().first?.get()
        let event = try HookIngressProcessor.normalize(
            XCTUnwrap(request),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(event.kind, .activityStarted)
        XCTAssertNotNil(event.agentID, "the call names the subagent that made it")
        XCTAssertNotEqual(event.agentID, .some("agent-a"), "and names it by its redacted label")
    }

    func testExecutableDropsACodexServiceSessionOutsideTheIndex() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let codexHomeURL = directoryURL.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"id":"user-thread"}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("session_index.jsonl")
        )

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let unexpected = expectation(description: "service session reaches ingress")
        unexpected.isInverted = true
        let ingress = UnixSocketIngress(socketPath: socketPath) { _ in
            unexpected.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        let sender = try runSender(
            input: Data(#"{"session_id":"service-thread"}"#.utf8),
            arguments: [
                "--source", "codex",
                "--event", "SessionStart",
                "--socket", socketPath,
            ],
            environment: environment
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [unexpected], timeout: 0.2)
    }

    func testExecutableDeliversAnIndexedCodexSession() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let codexHomeURL = directoryURL.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"id":"user-thread"}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("session_index.jsonl")
        )

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let received = expectation(description: "indexed Codex session reaches ingress")
        let results = IngressResults()
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomeURL.path
        let sender = try runSender(
            input: Data(#"{"session_id":"user-thread","cwd":"/tmp/agent-watch"}"#.utf8),
            arguments: [
                "--source", "codex",
                "--event", "SessionStart",
                "--socket", socketPath,
            ],
            environment: environment
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [received], timeout: 1)
        let request = try XCTUnwrap(try results.snapshot().first?.get())
        XCTAssertEqual(request.source, .codex)
        XCTAssertNil(request.description?.title)
        XCTAssertEqual(request.description?.projectName, "agent-watch")
    }

    /// The background flag is lifted out of `tool_input`, which is redacted whole. This test
    /// is the guard on both halves of that claim: the flag arrives, and the command it sat
    /// next to does not.
    func testExecutableDeliversTheBackgroundFlagWithoutTheCommandItSatNextTo() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "background flag arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let payload =
            "{\"session_id\":\"session\",\"tool_use_id\":\"call\",\"tool_name\":\"Bash\","
            + "\"tool_input\":{\"command\":\"tail -f /var/log/secret.log\",\"run_in_background\":true}}"
        let sender = try runSender(
            input: Data(payload.utf8),
            arguments: [
                "--source", "claude",
                "--event", "PreToolUse",
                "--socket", socketPath,
            ]
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [received], timeout: 1)
        let request = try XCTUnwrap(try results.snapshot().first?.get())

        XCTAssertEqual(request.toolRunsInBackground, true)

        let wire = try XCTUnwrap(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        XCTAssertFalse(wire.contains("secret.log"), "the command must not cross the wire")
        XCTAssertFalse(wire.contains("tail -f"), "the command must not cross the wire")
    }

    func testExecutableDeliversStatusLineTelemetryWithAShortExplicitDeadline() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "status line arrives")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let sender = try runSender(
            input: Data(
                """
                {"session_id":"session-secret","context_window":{"total_input_tokens":85000,"used_percentage":42.5,"private":"secret-context"},"rate_limits":{"five_hour":{"used_percentage":17,"resets_at":2000000000},"seven_day":{"used_percentage":31}}}
                """.utf8
            ),
            arguments: [
                "--source", "claude",
                "--event", "StatusLine",
                "--socket", socketPath,
                "--timeout-ms", "100",
            ]
        )

        XCTAssertEqual(sender.status, 0)
        wait(for: [received], timeout: 1)
        let request = try XCTUnwrap(try results.snapshot().first?.get())
        XCTAssertEqual(request.declaredEvent, "StatusLine")
        guard case let .object(fields) = request.payload else {
            return XCTFail("Expected an object payload")
        }
        XCTAssertEqual(fields["context_total_input_tokens"], .number(85_000))
        XCTAssertEqual(fields["context_used_percentage"], .number(42.5))
        XCTAssertNotEqual(fields["session_id"], .string("session-secret"))
        let event = try HookIngressProcessor.normalize(request, observedAt: Date())
        XCTAssertEqual(event.contextTelemetry, .init(totalInputTokens: 85_000, usedPercentage: 42.5))
        XCTAssertEqual(event.usageLimits?.fiveHour?.usedPercentage, 17)
        XCTAssertEqual(event.usageLimits?.sevenDay?.usedPercentage, 31)
        let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(wire.contains("secret-context"))
        XCTAssertFalse(wire.contains("resets_at"))
    }

    func testSocketHasOwnerOnlyPermissions() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let ingress = UnixSocketIngress(socketPath: socketPath) { _ in }
        try ingress.start()
        defer { ingress.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testRejectsAnUnfinishedMessageAfterReadDeadline() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "partial message timeout")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        try withSocketAddress(for: socketPath) { address, length in
            guard connect(descriptor, address, length) == 0 else {
                throw SocketTestError.connectFailed
            }
        }
        let partialMessage = Data("{".utf8)
        partialMessage.withUnsafeBytes { buffer in
            _ = write(descriptor, buffer.baseAddress, buffer.count)
        }

        wait(for: [received], timeout: 1)
        XCTAssertEqual(results.snapshot(), [.failure(.readTimedOut)])
    }

    /// Events are lifecycle transitions, so their order is the whole of their meaning: a
    /// call that ends before it starts leaves a row claiming work nothing is doing. Two
    /// connections read side by side finish in whatever order their reads finish, which is
    /// not the order they arrived in.
    ///
    /// Made deterministic rather than left to a race: the first message is held open with
    /// its last byte missing while the second is sent whole. Reading them side by side, the
    /// second must win; reading them one after another, the first must.
    func testTwoEventsAreHandedOverInTheOrderTheyArrived() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "both events")
        received.expectedFulfillmentCount = 2
        // The pause below is the point of the test and must never be what fails it: with the
        // app's 200 ms the CI machine ran past the deadline and dropped the first event.
        let ingress = UnixSocketIngress(socketPath: socketPath, readTimeoutMilliseconds: 5_000) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        var first = try JSONEncoder().encode(request(named: "first"))
        first.append(0x0A)
        var second = try JSONEncoder().encode(request(named: "second"))
        second.append(0x0A)

        let firstDescriptor = try openConnection(to: socketPath)
        try writeBytes(first.dropLast(), to: firstDescriptor)

        let secondDescriptor = try openConnection(to: socketPath)
        try writeBytes(second, to: secondDescriptor)
        _ = shutdown(secondDescriptor, SHUT_WR)

        // Far inside the reader's deadline, so the first connection is slow rather than
        // abandoned.
        Thread.sleep(forTimeInterval: 0.06)
        try writeBytes(first.suffix(1), to: firstDescriptor)
        _ = shutdown(firstDescriptor, SHUT_WR)
        defer {
            close(firstDescriptor)
            close(secondDescriptor)
        }

        wait(for: [received], timeout: 2)
        XCTAssertEqual(
            results.snapshot().map { try? $0.get().declaredEvent },
            ["first", "second"]
        )
    }

    /// Anything on this machine can connect to the socket, so the likeliest thing to arrive
    /// after a real event is not a real event. Each way of being wrong has its own answer,
    /// and until now only the timeout was ever produced by a test.
    func testEachWayAMessageCanBeWrongHasItsOwnAnswer() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path

        XCTAssertEqual(try failure(sending: Data("not json at all\n".utf8), to: socketPath), .messageDecodingFailed)
        // A peer that connects and says nothing at all before hanging up.
        XCTAssertEqual(try failure(sending: Data(), to: socketPath), .malformedMessage)
        // Bulk with no line ending in it. Measured rather than assumed: what answers is the
        // read deadline, not the size cap — a megabyte of nonsense takes longer than 200 ms
        // to accumulate, so the reader gives up before the guard on `count` is ever reached.
        // The cap is the backstop behind the deadline, not the thing doing the work, and a
        // test asserting otherwise would describe a path this listener does not take.
        let oversize = Data(repeating: 0x41, count: UnixSocketIngress.maximumMessageByteCount + 1)
        XCTAssertEqual(try failure(sending: oversize, to: socketPath), .readTimedOut)
    }

    /// The socket path is a name in a folder the app does not own outright. Finding a regular
    /// file there is somebody else's file, and deleting it to make room would be destroying
    /// what it refuses to look at.
    func testAnOrdinaryFileWhereTheSocketGoesIsRefusedRatherThanDeleted() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let socketURL = directoryURL.appendingPathComponent("agent-watch.sock")
        try Data("somebody else's file".utf8).write(to: socketURL)

        var ingress: UnixSocketIngress? = UnixSocketIngress(socketPath: socketURL.path) { _ in }
        XCTAssertThrowsError(try ingress?.start()) { error in
            XCTAssertEqual(error as? UnixSocketIngressError, .existingPathIsNotSocket)
        }
        ingress?.stop()
        ingress?.stop()
        ingress = nil
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "somebody else's file")
    }

    func testStoppingPreservesAFileThatReplacedTheOwnedSocket() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let socketURL = directoryURL.appendingPathComponent("agent-watch.sock")
        var ingress: UnixSocketIngress? = UnixSocketIngress(socketPath: socketURL.path) { _ in }
        try ingress?.start()
        try FileManager.default.removeItem(at: socketURL)
        try Data("replacement".utf8).write(to: socketURL)

        ingress?.stop()
        ingress = nil

        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "replacement")
    }

    func testRepeatedStopDoesNotRemoveTheNextListenersSocket() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        var first: UnixSocketIngress? = UnixSocketIngress(socketPath: socketPath) { _ in }
        try first?.start()
        first?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        let second = UnixSocketIngress(socketPath: socketPath) { _ in }
        try second.start()
        defer { second.stop() }

        first?.stop()
        first = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStoppingPreservesAReplacementSocketOwnedByAnotherListener() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let first = UnixSocketIngress(socketPath: socketPath) { _ in }
        try first.start()
        let second = UnixSocketIngress(socketPath: socketPath) { _ in }
        try second.start()
        defer { second.stop() }

        first.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    /// Starting twice is what a retry looks like, and the second start must not take the
    /// listener away from the first.
    func testStartingAnAlreadyStartedListenerChangesNothing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let socketPath = directoryURL.appendingPathComponent("agent-watch.sock").path
        let results = IngressResults()
        let received = expectation(description: "still listening")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        try ingress.start()
        defer { ingress.stop() }

        let request = request(named: "SessionStart")
        try send(request, to: socketPath)
        wait(for: [received], timeout: 1)
        XCTAssertEqual(results.snapshot(), [.success(request)])
    }

    /// Sends bytes on a fresh listener and answers with the one failure they produced.
    private func failure(sending bytes: Data, to socketPath: String) throws -> UnixSocketIngressError? {
        let results = IngressResults()
        let received = expectation(description: "a refusal")
        let ingress = UnixSocketIngress(socketPath: socketPath) { result in
            results.append(result)
            received.fulfill()
        }
        try ingress.start()
        defer { ingress.stop() }

        let descriptor = try openConnection(to: socketPath)
        defer { close(descriptor) }
        // Writes as much as the listener will take. A message it refuses closes the
        // connection under this write, and stopping there is the honest end of the send —
        // the refusal has already happened and is what the test is waiting for.
        bytes.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else {
                    return
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
        _ = shutdown(descriptor, SHUT_WR)

        wait(for: [received], timeout: 2)
        guard case let .failure(error)? = results.snapshot().first else {
            return nil
        }
        return error
    }

    private func request(named event: String) -> HookIngressRequest {
        HookIngressRequest(
            source: .codex,
            declaredEvent: event,
            payload: .object(["session_id": .string("session")])
        )
    }

    private func openConnection(to socketPath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        // What the real sender does, and for the same reason: a listener that refuses a
        // message closes the connection under a writer still writing it, and the default
        // answer to that is a signal that kills the process.
        var suppressSIGPIPE: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSIGPIPE,
            socklen_t(MemoryLayout<Int32>.size)
        )
        try withSocketAddress(for: socketPath) { address, length in
            guard Darwin.connect(descriptor, address, length) == 0 else {
                throw SocketTestError.connectFailed
            }
        }
        return descriptor
    }

    private func writeBytes(_ bytes: some DataProtocol, to descriptor: Int32) throws {
        for byte in bytes {
            var value = byte
            guard Darwin.write(descriptor, &value, 1) == 1 else {
                throw SocketTestError.writeFailed
            }
        }
    }

    private func send(_ request: HookIngressRequest, to socketPath: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        try withSocketAddress(for: socketPath) { address, length in
            guard connect(descriptor, address, length) == 0 else {
                throw SocketTestError.connectFailed
            }
        }

        var message = try JSONEncoder().encode(request)
        message.append(0x0A)
        try message.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SocketTestError.writeFailed
            }

            var pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                guard written > 0 else {
                    throw SocketTestError.writeFailed
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
        _ = shutdown(descriptor, SHUT_WR)
    }

    private func runSender(
        input: Data,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> SenderRun {
        let process = Process()
        process.executableURL = packageRootURL.appendingPathComponent(".build/debug/AgentWatchSend")
        process.arguments = arguments
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        return SenderRun(
            status: process.terminationStatus,
            standardOutput: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func withSocketAddress<T>(
        for path: String,
        body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        guard var address = PosixSocket.makeAddress(path: path) else {
            throw SocketTestError.invalidPath
        }
        return try PosixSocket.withSockaddr(&address, body)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("agent-watch-ingress-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum SocketTestError: Error {
    case connectFailed
    case invalidPath
    case writeFailed
}

private struct SenderRun {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private final class IngressResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<HookIngressRequest, UnixSocketIngressError>] = []

    func append(_ result: Result<HookIngressRequest, UnixSocketIngressError>) {
        lock.lock()
        values.append(result)
        lock.unlock()
    }

    func snapshot() -> [Result<HookIngressRequest, UnixSocketIngressError>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ControlDeliveryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
