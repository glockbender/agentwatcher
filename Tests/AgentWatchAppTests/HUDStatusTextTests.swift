import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// What a row says once the phase has moved to the lamp and staleness to the timer.
@MainActor
final class HUDStatusTextTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    func testCountsWaitingActivitiesByKind() {
        let activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: start),
            SessionActivity(id: "agent", kind: .subagent, startedAt: start),
            SessionActivity(id: "agent-2", kind: .subagent, startedAt: start),
        ]

        let counts = activityCounts(for: snapshot(phase: .waitingForChildren, activities: activities))

        XCTAssertEqual(counts.map(\.kind), [.subagent, .shell], "the order is fixed, not the arrival order")
        XCTAssertEqual(counts.map(\.count), [2, 1])
    }

    /// An advisor call is the one activity no hook announces, so a row that did not know the
    /// kind would show nothing at all while the session sat waiting on it.
    ///
    /// It stands beside compaction and for the same reason: both mean the session is doing
    /// nothing else, which is the answer to "why has this row gone quiet". So it is second in
    /// the order and, like compaction, carries no number — the turn waits on one advisor call
    /// at a time, and a digit that never varies takes room in every row and answers nothing.
    func testAnAdvisorCallIsCountedBesideCompactionAndWithoutANumber() {
        let activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: start),
            SessionActivity(id: "advisor", kind: .advisor, startedAt: start),
            SessionActivity(id: "compaction", kind: .compaction, startedAt: start),
        ]

        let counts = activityCounts(for: snapshot(phase: .executing, activities: activities))

        XCTAssertEqual(counts.map(\.kind), [.compaction, .advisor, .shell])
        XCTAssertNil(counterText(for: .advisor, count: 1), "a digit that never varies says nothing")
        XCTAssertEqual(ActivityIcon.name(for: .advisor, count: 1), "asking the advisor")
    }

    /// Each counter carries its own tooltip, and the number is what raises the question, so
    /// the number belongs in the answer.
    func testEachCounterExplainsItselfInWordsAndAgreesWithItsNumber() {
        XCTAssertEqual(ActivityIcon.name(for: .subagent, count: 1), "1 subagent")
        XCTAssertEqual(ActivityIcon.name(for: .subagent, count: 3), "3 subagents")
        XCTAssertEqual(ActivityIcon.name(for: .shell, count: 2), "2 shell commands")
        XCTAssertEqual(ActivityIcon.name(for: .backgroundTask, count: 1), "1 background task")
        XCTAssertEqual(ActivityIcon.name(for: .tool, count: 4), "4 tool calls")

        // Said once in front of the whole list, and "waiting on" rather than "running": a
        // command sent to the background returns its result at once and keeps running, so it
        // is not among these.
        var busy = snapshot(phase: .executing)
        busy.activities = [
            SessionActivity(id: "agent", kind: .subagent, startedAt: start),
            SessionActivity(id: "shell", kind: .shell, startedAt: start),
            SessionActivity(id: "shell-2", kind: .shell, startedAt: start),
        ]

        let line = activitiesText(for: busy)
        XCTAssertEqual(line, "waiting on 1 subagent · 2 shell commands")
        XCTAssertEqual(line.components(separatedBy: "waiting on").count - 1, 1, "said once, not per count")
        XCTAssertFalse(line.contains("running"))
        XCTAssertEqual(activitiesText(for: snapshot(phase: .idle)), "", "a quiet session waits on nothing")
    }

    /// A symbol nobody can read is worse than the word it replaced, so every kind has to
    /// resolve to a real symbol on this system rather than silently to nothing.
    func testEveryActivityKindHasASymbolThisSystemActuallyHas() {
        for kind in [ActivityKind.subagent, .shell, .backgroundTask, .tool] {
            XCTAssertNotNil(ActivityIcon.image(for: kind), "\(kind) has no symbol")
        }
    }

    /// The row answers how full the window is, not how much is in it. The count is long —
    /// Codex reports millions — and states a number nobody can act on without knowing what it
    /// is a fraction of. It keeps its place in the hover card, where both fit.
    func testTheRowSaysHowFullTheContextIsRatherThanHowLargeItIs() {
        var session = snapshot(phase: .executing)
        session.contextTelemetry = .init(totalInputTokens: 85_000, usedPercentage: 42.5)

        XCTAssertEqual(widgetContextText(for: session), "43%")
    }

    /// With no percentage the count is all there is, and an empty column would read as
    /// "context unknown" for a session whose context is perfectly well known.
    func testWithoutAPercentageTheRowFallsBackToTheCount() {
        var session = snapshot(phase: .executing)
        session.contextTelemetry = .init(totalInputTokens: 85_000, usedPercentage: nil)

        XCTAssertEqual(widgetContextText(for: session), "85k")
    }

    /// The phase, the source and the client are all images now, so no spelling of them may
    /// leak back into the text and spend width twice.
    func testAQuietSessionCarriesNoCountersAtAll() {
        var claudeDesktop = snapshot(phase: .executing)
        claudeDesktop.clientKind = .desktop
        var codexCLI = snapshot(phase: .completed, source: .codex)
        codexCLI.clientKind = .cli

        XCTAssertTrue(activityCounts(for: claudeDesktop).isEmpty)
        XCTAssertNil(widgetContextText(for: claudeDesktop))
        XCTAssertTrue(activityCounts(for: codexCLI).isEmpty)
    }

    // MARK: - The lamp

    func testEveryPhaseHasItsOwnLamp() {
        let phases = SessionPhase.allCases

        let names = phases.map { SessionLamp.builtInAppearance(for: snapshot(phase: $0)).name }

        XCTAssertEqual(Set(names).count, phases.count, "each phase needs wording of its own for the tooltip")
    }

    /// Colour must not be the only carrier (`docs/architecture.md` §7). Written as the rule
    /// rather than as the case that happened to break it: the previous version named the
    /// three greys — idle, no signal and session closed — and the defaults have since given
    /// each of those a colour of its own, which would have retired the test rather than the
    /// rule. Stated this way it keeps its teeth whatever the default colours become.
    ///
    /// The rule binds the defaults only. What a person assembles in the settings window is
    /// theirs, and the hover card names every phase in words either way.
    func testNoTwoPhasesAreToldApartByColourAlone() {
        let looks = SessionPhase.allCases.map { ($0, SessionLamp.builtInAppearance(for: snapshot(phase: $0))) }

        for (onePhase, one) in looks {
            for (otherPhase, other) in looks where onePhase != otherPhase {
                guard one.color.srgbHex == other.color.srgbHex else {
                    continue
                }
                XCTAssertTrue(
                    one.motion != other.motion || one.isFilled != other.isFilled,
                    "\(onePhase) and \(otherPhase) share a colour with nothing else to separate them"
                )
            }
        }
    }

    /// The whole default lamp, as one picture per phase. Two phases drawn identically would
    /// be one state shown twice, whatever separates them in the model.
    func testEveryPhaseIsDrawnDifferentlyFromEveryOther() {
        let drawings = SessionPhase.allCases.map { phase in
            let look = SessionLamp.builtInAppearance(for: snapshot(phase: phase))
            return "\(look.color.srgbHex ?? "?")-\(look.motion)-\(look.isFilled)"
        }

        XCTAssertEqual(Set(drawings).count, SessionPhase.allCases.count)
    }

    func testWorkAndAttentionAreDistinguishedByMotionNotOnlyColour() {
        XCTAssertEqual(SessionLamp.builtInAppearance(for: snapshot(phase: .executing)).motion, .pulse)
        XCTAssertEqual(SessionLamp.builtInAppearance(for: snapshot(phase: .idle)).motion, .steady)
        XCTAssertEqual(
            SessionLamp.builtInAppearance(for: snapshot(phase: .waitingForUser, userInputRequestKind: .approval))
                .motion,
            .urgent
        )
        XCTAssertEqual(SessionLamp.builtInAppearance(for: snapshot(phase: .failed)).motion, .urgent)
    }

    func testTheTooltipSaysWhichKindOfAnswerIsWanted() {
        XCTAssertEqual(
            SessionLamp.builtInAppearance(for: snapshot(phase: .waitingForUser, userInputRequestKind: .approval)).name,
            "approval needed"
        )
        XCTAssertEqual(
            SessionLamp.builtInAppearance(for: snapshot(phase: .waitingForUser, userInputRequestKind: .selection)).name,
            "choice needed"
        )
    }

    /// Freshness stops tracking `no signal` the moment the phase is reached, so a timer
    /// that took its colour from freshness alone printed the age of a session nobody can
    /// vouch for in the same grey as one that answered a second ago.
    func testFreshnessSaysNothingAboutAPhaseItStoppedTracking() {
        let stale = snapshot(phase: .disconnected)

        XCTAssertEqual(
            SessionFreshnessEvaluator.evaluate(stale, now: start.addingTimeInterval(10_000)),
            .current,
            "this is the inheritance the row must not rely on"
        )
        XCTAssertEqual(SessionLamp.builtInAppearance(for: stale).name, "no signal")
    }

    // MARK: - The timer

    /// Three characters at every scale, so the column never moves.
    func testTheElapsedTimeChangesUnitRatherThanWidth() {
        XCTAssertEqual(compactElapsed(0), "0s")
        XCTAssertEqual(compactElapsed(59), "59s")
        XCTAssertEqual(compactElapsed(60), "1m")
        XCTAssertEqual(compactElapsed(59 * 60 + 59), "59m")
        XCTAssertEqual(compactElapsed(3_600), "1h")
        XCTAssertEqual(compactElapsed(23 * 3_600), "23h")
        XCTAssertEqual(compactElapsed(24 * 3_600), "1d")

        let scales: [TimeInterval] = [0, 59, 60, 3_599, 3_600, 86_400, 400 * 86_400]
        for interval in scales {
            XCTAssertLessThanOrEqual(compactElapsed(interval).count, 3, "\(interval) printed too wide")
        }
    }

    /// A clock correction can put the last event in the future. That is not an age.
    func testAClockRunningBackwardsReadsAsZero() {
        XCTAssertEqual(compactElapsed(-10), "0s")
    }

    func testShowsOnlyTheUsageWindowsTheProviderActuallyReported() {
        let text = widgetUsageText(
            for: AgentUsageLimits(
                source: .claude,
                fiveHour: .init(usedPercentage: 17),
                observedAt: start
            ))

        XCTAssertEqual(text, "Claude  ·  5h 17%")
    }

    private func snapshot(
        phase: SessionPhase,
        source: AgentSource = .claude,
        userInputRequestKind: UserInputRequestKind? = nil,
        activities: [SessionActivity] = []
    ) -> SessionSnapshot {
        testSession(
            source: source,
            phase: phase,
            userInputRequestKind: userInputRequestKind,
            activities: activities,
            lastObservedAt: start
        )
    }
}
