import AgentWatchCore
import Foundation

/// One session for a test to draw, measure or sweep.
///
/// Six test files each kept a private factory around the same `SessionSnapshot` literal,
/// differing only in which fields they bothered to fill. Every parameter here has a default,
/// so a caller states exactly what its own assertion depends on: `testSession(phase:
/// .waitingForUser, lastObservedAt: now)` is visibly a test about that phase and nothing else.
///
/// `lastObservedAt` is the one thing without a default. Almost every assertion in this target
/// is about how old a session looks, and a fixture that quietly chose its own clock would be
/// answering that question for the test.
func testSession(
    index: Int = 0,
    source: AgentSource = .claude,
    title: String? = "Session",
    mode: SessionMode = .unknown,
    phase: SessionPhase = .idle,
    userInputRequestKind: UserInputRequestKind? = nil,
    activities: [SessionActivity] = [],
    clientKind: SessionClientKind? = nil,
    lastObservedAt: Date
) -> SessionSnapshot {
    var session = SessionSnapshot(
        id: "\(source.rawValue):session-\(index)",
        source: source,
        arrivalIndex: index,
        title: title,
        mode: mode,
        phase: phase,
        userInputRequestKind: userInputRequestKind,
        activities: activities,
        lastObservedAt: lastObservedAt
    )
    session.clientKind = clientKind
    return session
}
