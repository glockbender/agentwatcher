import AgentWatchCore
import Foundation

/// A made-up list that plays through the kind of day the widget sees, for the settings window
/// to show what an order does with it.
///
/// A loop: every session ends the eight steps in the phase it started in, so the list can play
/// forever without a jump back to the start. Each step changes one session, which is all a
/// person needs to follow a row: something happened, and it moved or it did not.
///
/// Seven sessions, one per thing an order has to place — at work, waiting, finished, opened and
/// never used, lost, failed, closed — so that every block of `SessionBlock` has something in it.
struct SessionOrderDemo {
    private(set) var sessions: [SessionSnapshot]
    private(set) var now: Date
    private(set) var step = 0

    /// How far the demo's clock moves each step. Also what the window waits between steps.
    static let stepInterval: TimeInterval = 2

    /// Who changes, and into what — eight steps that bring every session back where it began.
    static let script: [(index: Int, phase: SessionPhase)] = [
        (2, .executing),
        (0, .completed),
        (1, .executing),
        (4, .executing),
        (2, .completed),
        (1, .waitingForUser),
        (0, .executing),
        (4, .failed),
    ]

    /// Whether the window plays the list for this order. Only where rows move by themselves:
    /// in the arrival order nothing does.
    static func plays(_ order: SessionOrder) -> Bool {
        switch order {
        case .recentActivity, .attention: true
        case .arrival, .blocks: false
        }
    }

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = now
        sessions = Self.cast(at: now)
    }

    /// The next step, and the clock moves on with it: the session that changed is the one
    /// heard from last.
    mutating func advance() {
        let (index, phase) = Self.script[step % Self.script.count]
        now += Self.stepInterval
        sessions[index].phase = phase
        sessions[index].lastObservedAt = now
        if phase.meansTheSessionHasWorked {
            sessions[index].workedOnce = true
        }
        step += 1
    }

    private static func cast(at now: Date) -> [SessionSnapshot] {
        [
            session(0, "Fix the flaky login test", .executing, heard: now - 4, worked: true),
            session(1, "Port the probe to the new API", .waitingForUser, heard: now - 30, worked: true),
            session(2, "Review the release notes", .completed, heard: now - 90, worked: true),
            // Opened long enough ago to have dropped out of the active ones, and never asked a
            // thing — the row names its project, the way a real one does.
            session(3, nil, .idle, heard: now - 7_200, worked: false),
            session(4, "Refactor the ingress", .failed, heard: now - 240, worked: true),
            session(5, "Update the dependencies", .sessionClosed, heard: now - 600, worked: true),
            session(6, "Tidy the changelog", .disconnected, heard: now - 2_400, worked: true),
        ]
    }

    private static func session(
        _ index: Int,
        _ title: String?,
        _ phase: SessionPhase,
        heard: Date,
        worked: Bool
    ) -> SessionSnapshot {
        var session = SessionSnapshot(
            id: "demo:session-\(index)",
            source: index.isMultiple(of: 2) ? .claude : .codex,
            arrivalIndex: index,
            title: title,
            projectName: "agent-watch",
            phase: phase,
            lastObservedAt: heard,
            clientKind: .cli
        )
        session.workedOnce = worked
        return session
    }
}
