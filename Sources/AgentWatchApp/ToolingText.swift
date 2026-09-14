import AgentWatchCore
import Foundation

// Every word the `Tooling…` window says, and nothing else. Split out of `WidgetText`, where
// it was the largest third of a file named after the widget and read by `ToolingReport`
// alone: a person looking for the wording of an install step had no reason to open a file
// about rows.

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
    "Takes a click on a session's row to its terminal tab, not just to the IDE window. Optional. "
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
