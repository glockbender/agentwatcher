import AgentWatchCore
import AppKit

/// The activity counters a row shows, in a fixed order so they never swap places between
/// two refreshes.
///
/// Returned as counts rather than as one string: each counter carries its own symbol, and
/// a single label could explain none of them.
func activityCounts(for snapshot: SessionSnapshot) -> [(kind: ActivityKind, count: Int)] {
    let grouped = Dictionary(grouping: snapshot.activities, by: \.kind)
    // Compaction first, then the advisor: while either runs the session is doing nothing
    // else, and together they are the answer to "why has this row gone quiet".
    return [ActivityKind.compaction, .advisor, .subagent, .shell, .backgroundTask, .tool]
        .compactMap { kind in
            grouped[kind].map { (kind: kind, count: $0.count) }
        }
}

/// The number beside a counter's symbol, or none when the number can only ever be one.
///
/// A session compacts one context at a time and consults one advisor at a time, so a `1`
/// there is a digit that never varies — it takes room in every row and answers nothing.
func counterText(for kind: ActivityKind, count: Int) -> String? {
    switch kind {
    case .compaction, .advisor: nil
    case .subagent, .shell, .backgroundTask, .tool: "\(count)"
    }
}

/// What the session is waiting on, as one line: `waiting on 1 subagent · 2 shell commands`.
///
/// "Waiting on", not "running", and said once rather than before every count. What is listed
/// is a call the agent has issued and not had a result for. A command sent to the background
/// returns its result at once and keeps running afterwards, so it is not here — calling the
/// number "running" made the widget look wrong to anyone who could see three background
/// shells and a count of one.
func activitiesText(for snapshot: SessionSnapshot) -> String {
    let counts = activityCounts(for: snapshot)
    guard !counts.isEmpty else {
        return ""
    }
    let listed =
        counts
        .map { ActivityIcon.name(for: $0.kind, count: $0.count) }
        .joined(separator: " · ")
    return "waiting on \(listed)"
}

/// How much of the context window the session has used, when the provider reported it.
///
/// The phase is not here: it is the lamp, because `⚙ working` and `✓ completed` spent a
/// fixed slice of every row on a fact a coloured dot states faster. Neither is staleness —
/// the row's timer already shows how long the session has been quiet, in less space than
/// `⚠ no fresh activity` took. The source and the client are not here either: they are
/// images placed before this text.
func widgetContextText(for snapshot: SessionSnapshot) -> String? {
    guard let telemetry = snapshot.contextTelemetry else {
        return nil
    }
    // The share, and only the share. The count is what a row used to carry beside it, and it
    // was both the longest thing in the row — Codex reports millions — and the least useful:
    // "how much is left" is the question, and an absolute number answers it only for someone
    // who already knows the size of the window. The count keeps its place in the hover card.
    guard let percentage = telemetry.usedPercentage else {
        // A count with nothing to be a fraction of is still worth more than a blank column,
        // which would read as "context unknown" for a session whose context is known.
        return compactTokenCount(telemetry.totalInputTokens)
    }
    return "\(Int(percentage.rounded()))%"
}

/// The interval a person picks, said the way it now works.
///
/// The number used to be a cadence — a read every N seconds, whatever was happening. Reads
/// follow hooks now, and N caps how often they may happen rather than setting when they do.
func transcriptIntervalMenuTitle(interval: TimeInterval?) -> String {
    guard let interval else {
        return "Off"
    }
    return "At most every \(Int(interval)) seconds"
}

/// The user asked for failures to be visible rather than absorbed, and a setting that only
/// shows its interval cannot answer "is it working". This line does: off, idle, reading, or
/// reading with something to report.
func transcriptMenuSummary(interval: TimeInterval?, isReading: Bool, faultedSessionCount: Int) -> String {
    guard interval != nil else {
        // What it costs, not just that it is off. No hook reports a tool call finishing —
        // `PostToolUse` is not registered, because it charges a process launch per call — so
        // with the reading off the row keeps a finished call until the turn ends.
        return "Not reading — a finished call stays until the turn ends"
    }
    guard isReading else {
        // Not a fault. Nothing is working, so there is nothing a transcript could add — see
        // `SessionSilence`.
        return "Nothing to read — no session is working"
    }
    guard faultedSessionCount > 0 else {
        return "Reading"
    }
    return "Reading · \(faultedSessionCount) session\(faultedSessionCount == 1 ? "" : "s") with a problem"
}

/// What a monitoring fault means, in a sentence.
///
/// Says what is not known rather than naming the mechanism that failed. "No transcript
/// found" is something a person can act on — the session moved, or the agent changed where
/// it writes; `transcriptNotFound` is a symbol from the source code.
func monitoringFaultText(for fault: MonitoringFault) -> String {
    switch fault {
    case .transcriptNotFound:
        "No transcript found for this session — endings hooks miss will not show"
    case .transcriptUnreadable:
        "This session's transcript could not be read"
    case .transcriptResynchronized:
        "Skipped ahead in the transcript — some endings were missed"
    case .unexplainedSilence:
        "Says it is working, nothing is running, and nothing has been heard"
    }
}

/// The same fault in three words, for the debug log where one line is one event.
func monitoringFaultSummary(for fault: MonitoringFault) -> String {
    switch fault {
    case .transcriptNotFound: "transcript not found"
    case .transcriptUnreadable: "transcript unreadable"
    case .transcriptResynchronized: "transcript re-synced"
    case .unexplainedSilence: "unexplained silence"
    }
}

/// What a row calls the session it shows.
///
/// The agent's own name for it, wherever the agent has given one, and the directory it is
/// working in wherever it has not. A row with neither is a lamp and a clock, which says less
/// than nothing.
///
/// The directory is marked as the stand-in it is. A bare project name sits in the same place
/// and the same type as a real one and reads as a name the agent chose, so a person looking
/// down the list cannot tell which rows are still waiting to be named — and two sessions in
/// one repository become two rows with the same name and no way to tell them apart.
///
/// Every row falls back, not only one built from a live process: a session started and left
/// at its prompt has a hook, a project and a process number, and no name until the person
/// asks it something — which may be never. Observed sitting in the widget as an empty row
/// for minutes.
///
/// The card does not do the same, and that is why this rule lives here rather than there: a
/// card has room for a line naming the project, and a name line repeating it would say the
/// same word twice.
func rowName(for snapshot: SessionSnapshot, showsSessionTopic: Bool) -> String? {
    guard showsSessionTopic else {
        return nil
    }
    if let title = snapshot.title?.nonEmpty {
        return title
    }
    return snapshot.projectName?.nonEmpty.map { "\(noNameYet) in \($0)" }
}

/// Stands where a name would be, and is not one. In brackets because nothing an agent
/// writes arrives in brackets, so the row needs no second reading.
let noNameYet = "[still no name]"

/// Everything known about a session, as the lines of its hover card.
///
/// One card for the whole row replaced a tooltip on each picture. A row is a handful of
/// small targets, and hunting them one at a time to assemble a picture of one session is
/// more work than reading six lines once.
///
/// A line the session cannot answer is left out rather than printed empty.
@MainActor
func hoverCardText(
    for snapshot: SessionSnapshot,
    now: Date,
    showsSessionTopic: Bool = true,
    /// Optional, and `nil` is not `.nowhere`: one means nobody asked where the session is,
    /// the other means somebody asked and the host is gone. Only the second is worth a line.
    locator: SessionLocator? = nil
) -> String {
    let identity = [
        AgentIcon.name(for: snapshot.source),
        // Where the session is read rather than where it runs: a background session on
        // screen in a terminal says `CLI`, because that terminal is what a click reaches.
        snapshot.hostKind.map(SessionClientIcon.name(for:)),
        // Whose thread this is belongs with what it is rather than on a line of its own. A
        // person reading the top of the card is asking one question, and "Codex · Desktop ·
        // subagent Darwin · working" answers all of it at once.
        threadText(for: snapshot),
        // The wording is never overridden — only the colour and the motion are.
        SessionLamp.builtInAppearance(for: snapshot).name,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")

    // Its own line: a model name is long, and it belongs to neither the identity above it nor
    // the place below. No label — a model name reads as nothing else in this card.
    let model = [snapshot.modelName, snapshot.reasoningEffort]
        .compactMap { $0 }
        .joined(separator: " · ")

    let place = [snapshot.projectName, snapshot.gitBranch]
        .compactMap { $0 }
        .joined(separator: " · ")

    let work = activitiesText(for: snapshot)

    let context = snapshot.contextTelemetry.map { telemetry in
        let tokens = "\(compactTokenCount(telemetry.totalInputTokens)) tokens in context"
        return telemetry.usedPercentage.map { "\(Int($0.rounded()))% of context · \(tokens)" } ?? tokens
    }

    // The setting says "stop showing the topic", and a card that showed it anyway would
    // keep exactly the promise the rows had just stopped keeping.
    let name = showsSessionTopic ? snapshot.title?.nonEmpty : nil

    // The line tells a person how far one click on the row gets them, and at the two finer
    // levels where to look for the rest of the way. For a background session it says that
    // the click opens a tab rather than raising one, which is a different promise.
    let focus = focusHint(
        locator,
        namesTheSessionAbove: name != nil,
        runsWithoutAWindow: snapshot.hostKind == .background
    )

    return [
        name,
        identity,
        model.isEmpty ? nil : model,
        place.isEmpty ? nil : place,
        "Last event \(compactElapsed(now.timeIntervalSince(snapshot.lastObservedAt))) ago",
        work.isEmpty ? nil : work,
        context,
        // After everything the session itself has to say, because it qualifies all of it: how
        // much of the lines above is still being watched. The focus hint stays below it, being
        // the one line that asks the reader to do something rather than telling them anything.
        snapshot.monitoringFault.map(monitoringFaultText(for:)),
        focus,
        dismissHint(SessionPresence.dismissal(of: snapshot, now: now), now: now),
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
}

/// Why the `×` on this row is greyed, and when it stops being.
///
/// Said only in that one case. A button that works needs no sentence, and a row that offers
/// none is a session still at work — there is nothing there a person is being refused. This
/// is the whole of "disable and explain": the control stays put, and the card carries the
/// reason a row has no room for.
func dismissHint(_ dismissal: RowDismissal, now: Date) -> String? {
    guard case let .notYet(at) = dismissal else {
        return nil
    }
    return
        "× in \(compactElapsed(at.timeIntervalSince(now))) — the row is kept until then in case the session speaks again"
}

/// What one click on the row will actually reach, in one line.
///
/// Deliberately the weaker claim. A click does now reach the tab itself — through the plugin
/// in a JetBrains IDE, through AppleScript in Ghostty — but neither route is certain: the
/// plugin may not be installed, and a tab may be named after two sessions at once. So the
/// line promises the part that always happens and names the rest, which is what a person
/// needs to finish the trip with their own eyes when the tab step declines.
func focusHint(
    _ locator: SessionLocator?,
    namesTheSessionAbove: Bool,
    runsWithoutAWindow: Bool = false
) -> String? {
    guard let locator else {
        return nil
    }
    guard let application = locator.applicationName else {
        // Two different absences, and the difference is what a person does next. A host that
        // is gone may come back; a background session never had a window at all, so a click
        // opens one — a terminal tab with `claude attach` typed into it — and the line
        // names the command so that a person can do the same by hand anywhere else.
        return runsWithoutAWindow
            ? "Click opens it in a new Ghostty tab with `claude attach` — a background session has no window of its own"
            : "No window to bring forward"
    }
    let brings = "Click brings \(application) forward"
    // Pointed at the card's own first line rather than repeated here, and only when that
    // line is there: with the topic switched off the card must not say the name by the back
    // door, and a card that pointed at a line it had just been told to drop would point at
    // nothing.
    let tab = locator.tabName != nil && namesTheSessionAbove ? "terminal tab named above" : nil
    // The window, not the project: the card names the project a line above already, and
    // what this adds is which of an IDE's several windows to expect.
    let window = locator.projectName.map { "the \($0) window" }

    let rest = [window, tab].compactMap { $0 }.joined(separator: ", ")
    return rest.isEmpty ? brings : "\(brings) — \(rest)"
}

/// Whose thread a row is, when it is not a person's.
///
/// Silent for a person's own thread, which is what a row is unless something says otherwise,
/// and silent for Claude, which never says: a Claude subagent's work counts as its parent's
/// and never becomes a row of its own. Saying "user thread" on every other row would spend a
/// line on the absence of news.
func threadText(for snapshot: SessionSnapshot) -> String? {
    switch snapshot.threadKind {
    case .none, .user:
        return nil
    case .subagent:
        return snapshot.threadNickname.map { "subagent \($0)" } ?? "subagent"
    case .review:
        return "review thread"
    }
}

/// Time since the session's last event, in three characters: a number and its unit.
///
/// The unit changes rather than the width, so the column never moves: seconds up to a
/// minute, then minutes up to an hour, then hours, then days. A clock that ran backwards —
/// a correction from a time server, typically — reads as `0s` rather than as a negative age.
func compactElapsed(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds < 60 {
        return "\(seconds)s"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)h"
    }
    return "\(min(99, hours / 24))d"
}

// No actor: nothing here touches AppKit. It was `@MainActor` only because everything in this
// file was, which put three string functions on the main actor and every test around them
// with it. `AgentIcons.swift` already carries the one-word fix (`nonisolated static func`).
func widgetUsageText(for limits: AgentUsageLimits) -> String {
    // The account, not the product: these are the limits of a Claude subscription, not of
    // Claude Code. `AgentIcon.name` answers the other question and deliberately differs.
    let source = limits.source == .claude ? "Claude" : "Codex"
    let windows = [
        limits.fiveHour.map { "5h \(Int($0.usedPercentage.rounded()))%" },
        limits.sevenDay.map { "7d \(Int($0.usedPercentage.rounded()))%" },
    ]
    .compactMap { $0 }
    .joined(separator: "  ·  ")
    return "\(source)  ·  \(windows)"
}

private func compactTokenCount(_ value: Int) -> String {
    value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
}

extension String {
    /// The string, unless it is blank. Lets an optional name and an empty one be one case.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

/// How the settings window talks about a phase.
///
/// Two strings rather than one, and neither is the row's own wording: a row says
/// `approval needed` or `choice needed` depending on what the session is waiting for, while
/// the window configures the phase itself and has only one row for it. Both switches are
/// exhaustive, so a new phase cannot be added without being named and explained.
///
/// The explanations are the `Значение` column of the phase table in `docs/architecture.md`
/// §7, in English. They are not written twice: if that table changes, so do these.
extension SessionPhase {
    /// The phase's own name, for a place that sets the phase up rather than showing a session.
    var settingsName: String {
        switch self {
        case .idle: "Idle"
        case .planning: "Planning"
        case .executing: "Working"
        case .waitingForChildren: "Waiting for subtasks"
        case .waitingForUser: "Waiting for you"
        case .completed: "Completed"
        case .failed: "Failed"
        case .disconnected: "No signal"
        case .sessionClosed: "Session closed"
        }
    }

    /// When the phase happens and what it means, for the lamp's row in the settings window.
    var explanation: String {
        switch self {
        case .idle:
            "The session has started and no turn has begun yet."
        case .planning:
            "The session is in plan mode: it is working out what to do rather than doing it."
        case .executing:
            "The main agent is running a turn."
        case .waitingForChildren:
            "The turn has finished, and a subagent it started is still running."
        case .waitingForUser:
            "The turn has stopped until you answer — a permission request, or a choice."
        case .completed:
            "The last turn finished, and the session is waiting for what you say next."
        case .failed:
            "A tool or the agent itself ended with an error."
        case .disconnected:
            """
            Nothing has arrived for a long time and nothing can confirm what the session is \
            doing. Reversible: the next event brings the session back.
            """
        case .sessionClosed:
            """
            The end is confirmed: the session was ended, its process exited, or the \
            application it ran in quit.
            """
        }
    }
}
