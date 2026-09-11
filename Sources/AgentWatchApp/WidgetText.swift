import AgentWatchCore
import AppKit

/// The activity counters a row shows, in a fixed order so they never swap places between
/// two refreshes.
///
/// Returned as counts rather than as one string: each counter carries its own symbol and
/// its own tooltip, and a single label could explain none of them.
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
@MainActor
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
/// How far Agent Watch got into one agent's hooks, in one sentence.
///
/// Six states, six answers, and the two that mean something is wrong name what rather than
/// only that. The window has room the menu line did not, so each answer says the whole thing
/// instead of stopping at the fact.
func toolingHookStateText(state: ToolingInstallationState, hooks: [String]) -> String {
    switch state {
    case .absent:
        return "Not installed"
    case .installed:
        // The number, not a fraction of itself: with no optional hook there is nothing for
        // the whole to be a part of. It is still worth saying, because it is what a person
        // pays — one process launch per event.
        return "Installed — \(hooks.count) hooks, and events are arriving"
    case .unheard:
        return "Installed — \(hooks.count) hooks, and nothing has arrived from this agent yet"
    case let .incomplete(missing):
        return "Missing \(missing.count) of \(hooks.count): \(missing.joined(separator: ", "))"
    case let .stale(senderPaths):
        return "Registered against a sender that is gone: \(senderPaths.joined(separator: ", "))"
    case .unreadable:
        return "The file is there and cannot be read"
    }
}

/// What is left for the person to do, when anything is.
///
/// This is what the menu line had no room for. Both cases are facts about somebody else's
/// product rather than about this app, and both look exactly like a broken installation to
/// the person who does not know them.
func toolingHookNextStep(state: ToolingInstallationState, source: AgentSource, path: String) -> String? {
    switch state {
    case .unheard:
        switch source {
        case .claude:
            return "Claude Code loads a plugin once per session. Run /reload-plugins, or start a new session."
        case .codex:
            return "Codex runs a hook only after being told to trust its definition. Open Codex and accept the "
                + "prompt for these records; until then they sit in the file and never fire."
        }
    case .unreadable:
        // The one state where the app offers nothing: its only repair is a write, and this is
        // where writing over contents nobody can state is what must not happen.
        return "Agent Watch will not write over a file it cannot read. Repair or move \(path), then reopen "
            + "this window."
    case .absent, .installed, .incomplete, .stale:
        return nil
    }
}

/// The one press a hook row offers, if it offers one.
///
/// Installing over a broken installation repairs it — our entries are replaced, not repeated —
/// so a person fixes one problem with one press. The word changes with the problem, because
/// "Install" over an installation that is already there reads as a mistake.
func toolingHookActionTitle(state: ToolingInstallationState) -> String? {
    switch state {
    case .absent: "Install"
    case .installed, .unheard: "Remove"
    case .incomplete: "Repair"
    case .stale: "Point at this build"
    case .unreadable: nil
    }
}

/// Where the status line stands, and what pressing would do to what is already there.
func statusLineStateText(state: StatusLineState) -> String {
    switch state {
    case .notSet:
        "Not connected"
    case .connected:
        "Connected — your own command still runs behind it"
    case let .theirs(command):
        // The promise comes before the press. A person with their own status line needs to
        // know it survives before they find out.
        "Not connected — your own command is kept and wrapped, not replaced: \(command)"
    case .unreadable:
        "settings.json is there and cannot be read"
    }
}

/// What connecting the status line buys and what it costs.
///
/// Said on the row rather than after the press, because this is the one integration whose
/// price is noticeable and the one whose benefit nothing else can deliver.
func statusLineNextStep(state: StatusLineState) -> String? {
    switch state {
    case .notSet, .theirs:
        "The only place per-session context size and account usage reach the app. It costs one extra process "
            + "launch per status-line refresh — measured at about 1 s instead of 0.5 s — and the agent's turn "
            + "does not wait for it."
    case .connected, .unreadable:
        nil
    }
}

func statusLineActionTitle(state: StatusLineState) -> String? {
    switch state {
    case .notSet, .theirs: "Connect"
    case .connected: "Disconnect"
    case .unreadable: nil
    }
}

/// What the plugin does, and what the one press on a row asks. Said once, at the top of the
/// section, so no row has to repeat it.
///
/// The second sentence is there because the button it names is not on every row: `Check`
/// belongs to a running IDE only, and a button that is absent explains nothing by itself.
let idePluginPurpose =
    "Takes the ↗ press to the session's terminal tab, not just to the IDE window. Optional. "
    + "Check asks an IDE whether the plugin answers now, and needs that IDE running."

/// Said rather than left blank: an empty list means either no IDE here or an IDE somewhere
/// this app did not look, and only one of those is a problem.
let noJetBrainsIDEText = "Looked in /Applications, ~/Applications and everything running."

/// The route that does not exist yet, named anyway — it is the one that will matter, and
/// without it the file below reads as the intended way in.
let idePluginMarketplaceText =
    "Not published yet. It will replace the steps below with a search on the IDE's own Plugins page, "
    + "and updates will stop needing a restart."

/// Where the plugin stands in one IDE.
///
/// Two facts, in this order: whether the IDE is running, and what the plugin last said. The
/// first is here rather than implied by a missing button, and it also decides what the second
/// one can mean — nothing can be asked of an IDE that is not running.
///
/// The distinction the wording carries is between a file and an answer. A reply file proves
/// the plugin was loaded at some moment; only an answer to a question asked just now proves it
/// is loaded at this one.
func idePluginStateText(presence: IDEPluginPresence, isRunning: Bool) -> String {
    // Said in words only when it is not running, because that is the case that takes
    // something away — the row's dot carries the other one, and a line that opens with
    // "Running ·" on every row is four words nobody reads twice.
    let running = isRunning ? "" : "Not running · "
    switch presence {
    case .unaddressable(.bundleNamesNoScheme):
        return "No URL scheme in this bundle, so no address can reach it"
    case .unaddressable(.daemonMissing):
        return "The JetBrains daemon is missing, so no address reaches this IDE"
    case .unaddressable:
        return "Nothing can address this IDE"
    case .neverAnswered:
        return "\(running)the plugin has never answered here"
    case .checking:
        return "\(running)asked, waiting for an answer"
    case .askedAndSilent(let reply):
        guard reply != nil else {
            return "\(running)asked just now, no answer: the plugin is not loaded"
        }
        return "\(running)asked just now, no answer: the reply below is from a plugin that has gone"
    case .answeredEarlier(let reply):
        return "\(running)\(idePluginName(reply)) answered here earlier"
    case .confirmed(let reply):
        return "\(running)\(idePluginName(reply)) answered just now"
    }
}

/// The plugin's own version, when it reported one.
private func idePluginName(_ reply: IDEPluginReply) -> String {
    guard let version = reply.pluginVersion else {
        return "the plugin"
    }
    return "plugin \(version)"
}

/// What the plugin said about itself, under the row rather than in it.
func idePluginReplyDetails(presence: IDEPluginPresence) -> [String] {
    guard let reply = presence.reply else {
        return []
    }
    var parts: [String] = []
    if let answeredAt = reply.answeredAt {
        parts.append("Answered \(idePluginDateFormatter.string(from: answeredAt))")
    }
    if let ideBuild = reply.ideBuild {
        parts.append("IDE build \(ideBuild)")
    }
    return parts.isEmpty ? [] : [parts.joined(separator: " · ")]
}

/// The person's own calendar and clock: this is a timestamp they compare against "when did I
/// last open that IDE", so it is written the way their system writes dates.
private let idePluginDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

/// What is left to do with this IDE, when it differs from every other row.
///
/// Nothing for the ordinary states: what to do about a plugin that is not there is the same
/// for every IDE, and it is said once, under the file it is about.
func idePluginNextStep(presence: IDEPluginPresence, staged: StagedIDEPlugin?) -> String? {
    switch presence {
    case .unaddressable(.daemonMissing):
        return "Starting any JetBrains IDE once installs the daemon."
    case .unaddressable, .checking, .neverAnswered, .askedAndSilent:
        return nil
    case .confirmed(let reply), .answeredEarlier(let reply):
        return idePluginUpdateStep(installedVersion: reply.pluginVersion, staged: staged)
    }
}

/// The one thing worth saying to somebody whose plugin already works.
///
/// Only when the file is newer, and it says what the update costs: an install from a file
/// restarts the IDE whatever the plugin does — the platform decides that the moment it sees a
/// copy already installed. Measured; see `docs/session-focus-research.md`.
private func idePluginUpdateStep(installedVersion: String?, staged: StagedIDEPlugin?) -> String? {
    guard
        let staged,
        let installedVersion,
        ReleaseVersion.isNewer(staged.version, than: installedVersion)
    else {
        return nil
    }
    return "Newer file here: \(staged.version) against \(installedVersion). Updating from a file restarts the IDE."
}

/// Why the check is off, when it is.
///
/// Named where the button is, because the button is where a person looks after pressing
/// nothing. The one that matters is the first: an IDE has to be running to answer.
func idePluginCheckHint(presence: IDEPluginPresence, ide: InstalledJetBrainsIDE) -> String? {
    if case .unaddressable = presence {
        return "No address reaches this IDE"
    }
    guard ide.isRunning else {
        return "Start \(ide.product.name) — only a running IDE can answer"
    }
    return presence == .checking ? "Waiting for an answer" : nil
}

/// Why the way in is off, when it is.
func idePluginPageHint(ide: InstalledJetBrainsIDE, staged: StagedIDEPlugin?) -> String? {
    guard ide.productScheme != nil else {
        return "No address reaches this IDE"
    }
    return staged == nil ? "No plugin file to install from yet" : nil
}

/// What the dot beside an IDE's name means.
func toolingStatusHint(_ status: ToolingRowStatus) -> String {
    switch status {
    case .running: "Running"
    case .notRunning: "Not running"
    }
}

/// One title in every state, unlike the presses above it: this press does the same thing
/// whatever the IDE answered — it copies the path and opens the page where the IDE's own
/// dialog is. What changes with the state is the sentence above it, not the button.
let idePluginPageActionTitle = "Open Plugins"

/// Whether there is anything to install from.
func idePluginFileText(staged: StagedIDEPlugin?) -> String {
    staged.map(\.fileName) ?? "No plugin file here yet"
}

/// The steps, said once for every IDE above.
///
/// Here rather than on each row because they are the same steps whichever IDE it is, and
/// because they are about this file: the part Agent Watch cannot do is the paste, and the
/// dialog that accepts it belongs to the IDE.
func idePluginFileNextStep(staged: StagedIDEPlugin?) -> String? {
    guard staged == nil else {
        return "Open Plugins beside an IDE, then the gear on that page → Install Plugin from Disk → paste. "
            + "The path is already copied. A first install needs no restart."
    }
    // Deliberately not "build it": this is read by somebody who has the application and not
    // the repository. What it promises is a download; what it allows is a file put here by
    // hand, which is what the person writing the plugin does.
    return "Downloaded from the project's release page once there is one. Or put "
        + "agent-watch-ide-<version>.zip here yourself — the folder is yours to create."
}

/// What the widget says when nothing can report to it, and nothing otherwise.
///
/// The only thing Agent Watch asks for is one integration. Without any, it can show nothing
/// at all, and an empty widget with no explanation is the worst state it has. With one, it
/// says nothing about the others ever: running only Claude on a machine that also has Codex
/// is a decision, not a half-finished setup, and an app is not entitled to argue with it.
func toolingComplaint(states: [ToolingInstallationState]) -> String? {
    let canReport = states.contains {
        switch $0 {
        case .installed, .incomplete: true
        case .absent, .unheard, .stale, .unreadable: false
        }
    }
    guard !canReport else {
        return nil
    }
    // Not a reminder but a fact: these entries exist and cannot run, which is a different
    // problem from having none, and has a different answer.
    if states.contains(.unreadable) {
        // Ahead of the others because it is the one the app cannot fix: the rest end in a
        // press, this one ends in a person opening a file.
        return "A hook configuration file cannot be read. See Tooling."
    }
    if states.contains(where: { if case .stale = $0 { true } else { false } }) {
        return "Reinstall from Tooling — Agent Watch moved."
    }
    // Ahead of the advice below, and it replaces it: the hooks are installed, so installing
    // them is the one thing that cannot help. Where to go next differs by agent, and the
    // menu is where that is said.
    if states.contains(.unheard) {
        return "Hooks are installed, but no event has arrived. See Tooling."
    }
    // The action comes first so that it survives a narrow widget: the sentence wraps to two
    // lines and then truncates, and what a person needs is what to do, not a restatement of
    // the empty row they are already looking at.
    return "Install hooks from Tooling in the menu."
}

/// What to say after this agent's hooks are installed.
///
/// Claude Code needs the extra half-sentence and Codex needs a different one, and both are
/// facts about somebody else's product rather than about the menu — so they live here with the
/// rest of the wording instead of inside the action that happens to print them.
func hooksInstalledMessage(for source: AgentSource) -> String {
    switch source {
    // Not obvious, and it looks like a failure otherwise: a plugin Claude Code has already
    // loaded does not pick up new hooks by itself.
    case .claude: "Claude hooks installed — run /reload-plugins or start a new session"
    // Also not obvious, and it looks the same: Codex skips a hook whose definition it has not
    // been asked to trust, so the records are in place and nothing fires until a person says so.
    case .codex: "Codex hooks installed — approve them in Codex, or nothing will fire"
    }
}

/// What Claude Code's one status-line slot holds, and what pressing this would do to it.
func statusLineMenuTitle(state: StatusLineState) -> String {
    switch state {
    case .notSet:
        "Status line — not connected"
    case .connected:
        "Status line — connected"
    case .theirs:
        // The promise comes before the press. A person with their own status line needs to
        // know it survives before they find out.
        "Status line — not connected (your own command is kept)"
    case .unreadable:
        "Status line — settings.json cannot be read"
    }
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
        snapshot.clientKind.map(SessionClientIcon.name(for:)),
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

    // Said here rather than on the button, which carries no tooltip of its own: the line
    // tells a person how far one press gets them, and at the two finer levels where to look
    // for the rest of the way. For the one row whose button is grey it says why instead.
    let focus = focusHint(
        locator,
        namesTheSessionAbove: name != nil,
        runsWithoutAWindow: snapshot.clientKind == .background
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
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
}

/// What one press of `↗` will actually reach, in one line.
///
/// Deliberately the weaker claim. A press does now reach the tab itself — through the plugin
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
        // is gone may come back; a background session never had a window at all, which is
        // also why its button is grey rather than pressable.
        return runsWithoutAWindow
            ? "No window to bring forward — a background session runs in the agent's own pty"
            : "No window to bring forward"
    }
    let brings = "↗ brings \(application) forward"
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

@MainActor
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

@MainActor
private func compactTokenCount(_ value: Int) -> String {
    value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
}

/// How wide a label holding this text will actually be.
///
/// Measured through a real label rather than through `NSAttributedString.size()`, which
/// returns the width of the glyphs alone. A label is wider than its text — `NSTextField`
/// keeps a small inset around the cell — and budgeting by the glyph width alone left every
/// row a few points short of what it went on to lay out.
@MainActor
func labelWidth(of text: String, font: NSFont) -> CGFloat {
    guard !text.isEmpty else {
        return 0
    }
    let label = NSTextField(labelWithString: text)
    label.font = font
    return ceil(label.fittingSize.width)
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

    /// When the phase happens and what it means, for the row's tooltip.
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

// MARK: - Updates

/// What the update dialogs say.
///
/// One version number per sentence and no adjectives: the person is being interrupted, and
/// the only question worth their attention is whether to take the new build now.

let updateDownloadButton = "Download"
let updateInstallButton = "Install and Relaunch"
let updateLaterButton = "Not Now"
let updateOpenPageButton = "Open Release Page"
let updateCloseButton = "OK"

func updateSkipButton(version: String) -> String {
    "Skip \(version)"
}

func updateAvailableTitle(version: String) -> String {
    "Agent Watch \(version) is available"
}

func updateAvailableBody(ownVersion: String) -> String {
    """
    You have \(ownVersion). The download is about a megabyte and is installed by the app \
    itself, which then restarts.
    """
}

func updateReadyTitle(version: String) -> String {
    "Agent Watch \(version) is ready"
}

let updateReadyBody = """
    Installing replaces this copy and starts the new one. Sessions already being watched are \
    remembered and come back.
    """

let updateUpToDateTitle = "No update yet"

func updateUpToDateBody(version: String) -> String {
    "Agent Watch \(version) is the newest published build."
}

let updateCheckFailedTitle = "Could not check for updates"
let updateCheckFailedBody = "GitHub could not be reached. Nothing else is affected."

let updateFailedTitle = "Could not download the update"
let updateFailedBody = """
    The file did not arrive whole, or could not be unpacked. This copy is untouched — the \
    release page has the file to install by hand.
    """

let updateCannotReplaceTitle = "Could not replace this copy"
let updateCannotReplaceBody = """
    The new build was downloaded but this copy could not be written over, which usually means \
    it sits somewhere this account cannot change. The downloaded build is selected in the \
    Finder; move it over the old one yourself.
    """

/// Only ever seen by somebody running the app from a build directory, where the check is off
/// anyway — reached by pressing the menu item there.
let updateNoVersionTitle = "This build has no version"
let updateNoVersionBody = """
    It was started from a build directory rather than from an application bundle, so there is \
    nothing to compare against a release.
    """

let updateRelaunchFailedTitle = "Update installed, but the restart failed"
let updateRelaunchFailedBody = """
    The new version is in place. This window belongs to the old one, still running — quit it and \
    open Agent Watch again.
    """
