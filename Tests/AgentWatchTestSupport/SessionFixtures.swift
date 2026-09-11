import AgentWatchCore
import Foundation

/// One session for a test to draw, measure or sweep.
///
/// Every parameter has a default, so a caller states exactly what its own assertion depends
/// on: `testSession(phase: .waitingForUser, lastObservedAt: now)` is visibly a test about
/// that phase and nothing else.
///
/// `lastObservedAt` is the one thing without a default. Almost every assertion about a row
/// is about how old it looks, and a fixture that quietly chose its own clock would be
/// answering that question for the test.
public func testSession(
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
    SessionSnapshot(
        id: "\(source.rawValue):session-\(index)",
        source: source,
        arrivalIndex: index,
        title: title,
        mode: mode,
        phase: phase,
        userInputRequestKind: userInputRequestKind,
        activities: activities,
        lastObservedAt: lastObservedAt,
        clientKind: clientKind
    )
}

/// One event as the engine receives it, with the fields most tests never mention filled in.
///
/// Two fields follow from the kind so that an event is well-formed without the test saying
/// so: a completed activity names one, and a request for input says which kind.
public func testEvent(
    source: AgentSource = .claude,
    sessionLabel: String,
    kind: EventKind = .sessionStarted,
    observedAt: Date,
    mode: SessionMode? = nil,
    agentProcessID: Int32? = nil,
    clientKind: SessionClientKind? = nil,
    description: SessionDescription? = nil,
    contextTelemetry: SessionContextTelemetry? = nil
) -> EventEnvelope {
    EventEnvelope(
        source: source,
        sessionID: sessionLabel,
        description: description,
        activityID: kind == .activityCompleted ? "activity-1" : nil,
        observedAt: observedAt,
        kind: kind,
        mode: mode,
        userInputRequestKind: kind == .userInputRequired ? .approval : nil,
        agentProcessID: agentProcessID,
        clientKind: clientKind,
        contextTelemetry: contextTelemetry
    )
}

/// One Claude hook as the ingress hands it to the supervisor: the event under its own name,
/// the session it belongs to, and what the sender adds on the way.
public func testRequest(
    event: String,
    sessionID: String,
    agentProcessID: Int32? = nil,
    description: SessionDescription? = nil
) -> HookIngressRequest {
    HookIngressRequest(
        source: .claude,
        declaredEvent: event,
        payload: .object(["session_id": .string(sessionID)]),
        agentProcessID: agentProcessID,
        description: description
    )
}
