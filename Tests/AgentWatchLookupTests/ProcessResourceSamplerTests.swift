import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

/// Which processes the sampler reads and what it reads about each. The machine is invented:
/// which session a process belongs to is `ResourceAttributionTests`' question, not this one's.
final class ProcessResourceSamplerTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 2_000_000)
    private let desktopCodex =
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    func testHostIsFoundByItsArgumentsAndItsCommandsCarryThreadMarkers() {
        let machine = FakeMachine([
            500: FakeProcess(parent: 1, name: "codex", path: desktopCodex, arguments: [desktopCodex, "app-server"]),
            600: FakeProcess(parent: 1, name: "codex", path: desktopCodex, arguments: [desktopCodex, "exec-server"]),
            501: FakeProcess(parent: 500, name: "zsh", path: "/bin/zsh"),
            502: FakeProcess(parent: 501, name: "go", environment: ["CODEX_THREAD_ID": "thread-1"]),
            503: FakeProcess(parent: 500, name: "plata-mcp", workingDirectory: "/p/agent-watch"),
        ])
        var sampler = ProcessResourceSampler(kernel: machine.kernel)

        let table = sampler.sample(rootProcessIDs: [], at: moment)

        XCTAssertEqual(table.hosts, [SharedAgentHost(processID: 500, source: .codex)])
        XCTAssertEqual(table.processes.map(\.processID), [500, 501, 502, 503])
        XCTAssertEqual(
            table.processes.first { $0.processID == 502 }?.markers,
            [SessionMarker(source: .codex, label: HookCaptureRedactor.label(forRawIdentifier: "thread-1"))])
        XCTAssertEqual(table.processes.first { $0.processID == 503 }?.workingDirectory, "/p/agent-watch")
        XCTAssertNil(
            table.processes.first { $0.processID == 502 }?.workingDirectory,
            "only a host's own children are grouped by folder")
    }

    /// A row's tree is decided by the tree, so nothing in it has its environment read.
    func testRowTreeIsReadWithoutTouchingAnyEnvironment() {
        let machine = FakeMachine([
            100: FakeProcess(parent: 50, name: "claude", footprint: 200),
            101: FakeProcess(parent: 100, name: "plata-mcp", footprint: 160),
            102: FakeProcess(parent: 100, name: "zsh"),
            50: FakeProcess(parent: 1, name: "Claude"),
        ])
        var sampler = ProcessResourceSampler(kernel: machine.kernel)

        let table = sampler.sample(rootProcessIDs: [100], at: moment)

        XCTAssertEqual(table.processes.map(\.processID), [100, 101, 102])
        XCTAssertEqual(table.processes.first?.footprint, 200)
        XCTAssertEqual(machine.environmentReads(of: [100, 101, 102]), 0)
    }

    func testOrphanIsReadOnlyWhenItIsOursAndNamesASession() {
        let machine = FakeMachine(
            [
                200: FakeProcess(parent: 1, name: "node", environment: ["CLAUDE_CODE_SESSION_ID": "s"]),
                201: FakeProcess(parent: 200, name: "node"),
                300: FakeProcess(parent: 1, name: "Safari"),
                400: FakeProcess(parent: 1, name: "node", user: 0, environment: ["CLAUDE_CODE_SESSION_ID": "s"]),
                900: FakeProcess(parent: 1, name: "AgentWatch", environment: ["CLAUDE_CODE_SESSION_ID": "s"]),
            ],
            ownProcessID: 900
        )
        var sampler = ProcessResourceSampler(kernel: machine.kernel)

        let table = sampler.sample(rootProcessIDs: [], at: moment)

        XCTAssertEqual(table.processes.map(\.processID), [200, 201])
        XCTAssertEqual(table.processes.first?.markers.first?.source, .claude)
        XCTAssertNotNil(table.agentWatch, "Agent Watch is counted on its own line, never as an orphan")
    }

    /// An agent's command can start an installed application, which then carries the marker.
    /// The application is not leftover work; a browser a test left in a cache folder is.
    func testInstalledApplicationIsNoOrphanThoughItCarriesAMarker() {
        let marker = ["CODEX_THREAD_ID": "t"]
        let machine = FakeMachine([
            700: FakeProcess(
                parent: 1, name: "OrbStack", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack",
                environment: marker),
            701: FakeProcess(
                parent: 1, name: "Chromium",
                path: "/Users/someone/Library/Caches/ms-playwright/chromium/Chromium.app/Contents/MacOS/Chromium",
                environment: marker),
        ])
        var sampler = ProcessResourceSampler(kernel: machine.kernel)

        let table = sampler.sample(rootProcessIDs: [], at: moment)

        XCTAssertEqual(table.processes.map(\.processID), [701])
    }

    /// The markers of a process do not change while it lives, so they are read once. A new
    /// process under the same number is another process: its own markers are read.
    func testMarkersAreReadOncePerProcessAndAgainForANewProcessUnderTheSameNumber() {
        let machine = FakeMachine([
            200: FakeProcess(parent: 1, name: "node", startedAt: 1, environment: ["CLAUDE_CODE_SESSION_ID": "first"])
        ])
        var sampler = ProcessResourceSampler(kernel: machine.kernel)

        _ = sampler.sample(rootProcessIDs: [], at: moment)
        _ = sampler.sample(rootProcessIDs: [], at: moment.addingTimeInterval(5))
        XCTAssertEqual(machine.environmentReads(of: [200]), 1)

        machine.replace(
            200,
            with: FakeProcess(parent: 1, name: "node", startedAt: 2, environment: ["CLAUDE_CODE_SESSION_ID": "second"]))
        let table = sampler.sample(rootProcessIDs: [], at: moment.addingTimeInterval(10))

        XCTAssertEqual(machine.environmentReads(of: [200]), 2)
        XCTAssertEqual(
            table.processes.first?.markers.first?.label, HookCaptureRedactor.label(forRawIdentifier: "second"))
    }

    func testStartBufferHoldsArgumentsThenEnvironment() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        for word in ["/bin/x", "", "", "a", "", "K=V", "CLAUDE_CODE_SESSION_ID=abc", "", "", "executable_path=/bin/x"] {
            buffer.append(contentsOf: Array(word.utf8) + [0])
        }

        let parsed = AgentProcessLocator.parseStartBuffer(buffer)

        XCTAssertEqual(parsed.arguments, ["a", ""])
        XCTAssertEqual(parsed.environment, ["K=V", "CLAUDE_CODE_SESSION_ID=abc"])
    }

    func testLiveKernelReportsThisProcess() throws {
        let kernel = ProcessKernel.live
        let usage = try XCTUnwrap(kernel.usage(getpid()))
        let basics = try XCTUnwrap(kernel.basics(getpid()))

        XCTAssertGreaterThan(usage.footprint, 0)
        XCTAssertGreaterThan(usage.cpuTime, 0)
        XCTAssertEqual(basics.parentProcessID, getppid())
        XCTAssertEqual(basics.userID, getuid())
        XCTAssertGreaterThan(try XCTUnwrap(kernel.machineMemory()).physical, 0)
    }
}

private struct FakeProcess {
    var parent: Int32
    var name: String
    var user: uid_t = getuid()
    var startedAt: UInt64 = 1
    var path: String? = nil
    var arguments: [String]? = nil
    var environment: [String: String] = [:]
    var workingDirectory: String? = nil
    var footprint: UInt64 = 1
}

/// An invented machine, and a count of the environments read from it.
private final class FakeMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: FakeProcess]
    private var reads: [Int32: Int] = [:]
    private let ownProcessID: Int32

    init(_ processes: [Int32: FakeProcess], ownProcessID: Int32 = 999_999) {
        self.processes = processes
        self.ownProcessID = ownProcessID
    }

    func replace(_ processID: Int32, with process: FakeProcess) {
        lock.withLock { processes[processID] = process }
    }

    func environmentReads(of processIDs: [Int32]) -> Int {
        lock.withLock { processIDs.reduce(0) { $0 + (reads[$1] ?? 0) } }
    }

    private func process(_ processID: Int32) -> FakeProcess? {
        lock.withLock { processes[processID] }
    }

    var kernel: ProcessKernel {
        ProcessKernel(
            listProcessIDs: { [self] in lock.withLock { Array(processes.keys) } },
            basics: { [self] processID in
                process(processID).map {
                    ProcessBasics(
                        parentProcessID: $0.parent, userID: $0.user, startedAt: $0.startedAt,
                        commandName: $0.name)
                }
            },
            executablePath: { [self] in process($0)?.path },
            arguments: { [self] in process($0)?.arguments },
            environmentValues: { [self] processID, names in
                lock.withLock { reads[processID, default: 0] += 1 }
                return process(processID)?.environment.filter { names.contains($0.key) } ?? [:]
            },
            workingDirectory: { [self] in process($0)?.workingDirectory },
            usage: { [self] in
                process($0).map {
                    ProcessUsage(footprint: $0.footprint, resident: 1, cpuTime: 1, finishedChildrenCPUTime: 0)
                }
            },
            machineMemory: { MachineMemory(physical: 1, swapUsed: 0, swapTotal: 0, pressure: .normal) },
            ownProcessID: ownProcessID,
            userID: getuid(),
            applicationFolders: ["/Applications/"]
        )
    }
}
