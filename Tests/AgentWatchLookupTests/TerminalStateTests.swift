import Darwin
import Foundation
import XCTest

@testable import AgentWatchLookup

/// Whether an agent still has the terminal it was started in.
///
/// The three pairs below are the kernel's answers read off this machine on 2026-09-22
/// (Darwin 24.3.0, Claude Code 2.1.270 and 2.1.280): two `claude` processes whose JetBrains
/// terminal tab had been closed, the live sessions beside them, and the applications that
/// never had a terminal at all.
final class TerminalStateTests: XCTestCase {
    func testATerminalIsLostOnlyWhenTheProcessHadOneAndItIsGone() {
        // Both closed-tab processes: the flag still set, the device gone.
        XCTAssertEqual(AgentProcessLocator.terminalState(controlsATerminal: true, terminalDevice: -1), .lost)
        // Every live session: `ttys004` and its neighbours.
        XCTAssertEqual(
            AgentProcessLocator.terminalState(controlsATerminal: true, terminalDevice: 268_435_460),
            .attached
        )
        // PyCharm, GoLand, Finder: no flag, no device. Without the flag a missing device is
        // the ordinary state of an application, not a terminal that went away.
        XCTAssertEqual(AgentProcessLocator.terminalState(controlsATerminal: false, terminalDevice: -1), .neverHad)
    }

    /// The chain under the tab Ghostty 1.3.1 closed and kept on 2026-09-29: `claude` 52671,
    /// the `zsh` it was typed into, the `login` Ghostty started, all on `ttys024`, and Ghostty
    /// itself, with no terminal. A hang-up reaches the three and not Ghostty.
    func testAHangUpReachesTheAgentItsShellAndLoginButNotTheTerminalApplication() {
        let ttys024: dev_t = 268_435_480
        let records: [Int32: AgentProcessLocator.TerminalProcess] = [
            52671: .init(parentProcessID: 52482, terminalDevice: ttys024),
            52482: .init(parentProcessID: 52480, terminalDevice: ttys024),
            52480: .init(parentProcessID: 691, terminalDevice: ttys024),
            691: .init(parentProcessID: 1, terminalDevice: nil),
        ]

        XCTAssertEqual(
            AgentProcessLocator.terminalProcessChain(from: 52671) { records[$0] },
            [52671, 52482, 52480]
        )
    }

    /// A parent on another terminal is somebody else's session, however it came to start this
    /// one, and a hang-up of this terminal would never reach it.
    func testTheChainStopsAtAParentOnAnotherTerminal() {
        let records: [Int32: AgentProcessLocator.TerminalProcess] = [
            300: .init(parentProcessID: 200, terminalDevice: 24),
            200: .init(parentProcessID: 100, terminalDevice: 4),
        ]

        XCTAssertEqual(AgentProcessLocator.terminalProcessChain(from: 300) { records[$0] }, [300])
    }

    func testAProcessWithNoTerminalHasNoChainToHangUp() {
        let records: [Int32: AgentProcessLocator.TerminalProcess] = [
            300: .init(parentProcessID: 200, terminalDevice: nil)
        ]

        XCTAssertEqual(AgentProcessLocator.terminalProcessChain(from: 300) { records[$0] }, [])
        XCTAssertEqual(AgentProcessLocator.terminalProcessChain(from: 400) { records[$0] }, [])
    }

    /// A process can write to a terminal that was never its controlling one — which is what
    /// a child started with a pty for its output is — and that is still no terminal it lost.
    func testTheTerminalAProcessWritesToIsReadFromItsOwnDescriptors() throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&controller, &terminal, nil, nil, nil), 0)
        defer {
            close(controller)
            close(terminal)
        }
        let devicePath = try XCTUnwrap(ttyname(terminal).map { String(cString: $0) })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let handle = FileHandle(fileDescriptor: terminal, closeOnDealloc: false)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer { process.terminate() }

        XCTAssertEqual(AgentProcessLocator.terminalDevicePath(of: process.processIdentifier), devicePath)
        XCTAssertEqual(AgentProcessLocator.terminalState(of: process.processIdentifier), .neverHad)
    }

    func testAProcessWithNoTerminalOnItsDescriptorsNamesNone() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        XCTAssertNil(AgentProcessLocator.terminalDevicePath(of: process.processIdentifier))
    }

    func testAProcessNobodyHoldsHasNoTerminalState() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        XCTAssertNil(AgentProcessLocator.terminalState(of: process.processIdentifier))
        XCTAssertNil(AgentProcessLocator.terminalDevicePath(of: process.processIdentifier))
    }
}
