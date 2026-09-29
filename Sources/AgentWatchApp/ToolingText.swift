import AgentWatchCore
import Foundation

// Every word the `Tooling…` window says, and nothing else. Split out of `WidgetText`, where
// it was the largest third of a file named after the widget and read by `ToolingReport`
// alone: a person looking for the wording of an install step had no reason to open a file
// about rows.

/// How far Agent Watch got into one agent's hooks, in one line.
///
/// Six states, six answers, and the ones that mean something is wrong name what rather than
/// only that. Each starts with the mark the setup guide gives the same state — ✓ working,
/// ◑ waiting, ○ not there, ! needs you — and the words stay beside it: a shape alone is not
/// an answer (ADR-0003). ◑ rather than a clock: the system font has no ◷, and the fallback
/// drew it at half the size of the marks beside it. How many hooks there are is left out; it is a fact for the docs,
/// not something a person decides anything by.
func toolingHookStateText(state: ToolingInstallationState) -> String {
    switch state {
    case .absent:
        return "○ Not installed"
    case .installed:
        return "✓ Installed · events are arriving"
    case .unheard:
        return "◑ Installed · nothing has arrived yet"
    case let .incomplete(missing):
        return "! Hooks missing: \(missing.joined(separator: ", "))"
    case let .stale(senderPaths):
        return "! Points to a program that is gone: \(senderPaths.joined(separator: ", "))"
    case .unreadable:
        return "! The file exists but cannot be read"
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
            return "Open Codex and accept its prompt to trust these hooks. Until then they do not run."
        }
    case .unreadable:
        // The one state where the app offers nothing: its only repair is a write, and this is
        // where writing over contents nobody can state is what must not happen.
        return "Agent Watch does not change a file it cannot read. Fix or move \(path), then reopen this window."
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
        "○ Not connected"
    case .connected:
        "✓ Connected · your own command still runs"
    case let .theirs(command):
        // The promise comes before the press. A person with their own status line needs to
        // know it survives before they find out.
        "○ Not connected · your command is kept when you connect: \(command)"
    case .unreadable:
        "! settings.json exists but cannot be read"
    }
}

/// What connecting the status line buys and what it costs.
///
/// Said on the row rather than after the press, because this is the one integration whose
/// price is noticeable and the one whose benefit nothing else can deliver.
func statusLineNextStep(state: StatusLineState) -> String? {
    switch state {
    case .notSet, .theirs:
        "Adds each session's context size and your account usage to the widget. It runs one extra process "
            + "per refresh; the agent does not wait for it."
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

/// What the plugin does, and why it is installed from a file. Said once, at the top of the
/// section, so no row has to repeat it.
///
/// What `Check` needs is not said here: an IDE that is not running says so in its own row,
/// beside the greyed button, and that is where a person looks.
let idePluginPurpose =
    "Optional. A click on a row opens the exact terminal tab, not just the IDE window. "
    + "Not on JetBrains Marketplace yet: install it from the file below."

/// Said rather than left blank: an empty list means either no IDE here or an IDE somewhere
/// this app did not look, and only one of those is a problem.
let noJetBrainsIDEText = "Looked in /Applications, ~/Applications and everything running."

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
    let answer = idePluginAnswerText(presence: presence)
    guard !isRunning else {
        return answer.prefix(1).uppercased() + answer.dropFirst()
    }
    return "Not running · \(answer)"
}

/// What the plugin last said, starting in lower case so that it can follow "Not running ·".
private func idePluginAnswerText(presence: IDEPluginPresence) -> String {
    switch presence {
    case .unaddressable(.bundleNamesNoScheme):
        return "no URL scheme in this bundle, so no address can reach it"
    case .unaddressable(.daemonMissing):
        return "the JetBrains daemon is missing, so no address reaches this IDE"
    case .unaddressable:
        return "nothing can address this IDE"
    case .neverAnswered:
        return "the plugin has never answered here"
    case .checking:
        return "asked, waiting for an answer"
    case .askedAndSilent(let reply):
        guard reply != nil else {
            return "asked just now, no answer: the plugin is not loaded"
        }
        return "asked just now, no answer: the reply below is from a plugin that has gone"
    case .answeredEarlier(let reply):
        return "\(idePluginName(reply)) answered here earlier"
    case .confirmed(let reply):
        return "\(idePluginName(reply)) answered just now"
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
    // The IDE's build number stays in the reply file: it tells a person nothing the row's own
    // name does not, and it is there for whoever debugs the plugin.
    guard let answeredAt = reply.answeredAt else {
        return []
    }
    return ["Answered \(idePluginDateFormatter.string(from: answeredAt))"]
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
    return "Update available: \(staged.version) (installed: \(installedVersion)). Installing it restarts the IDE."
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
        return "Open Plugins beside an IDE copies this file's path and opens that IDE's Plugins page. "
            + "There, choose the gear → Install Plugin from Disk, and paste. A first install needs no restart."
    }
    // Deliberately not "build it": this is read by somebody who has the application and not
    // the repository.
    return "Download agent-watch-ide-<version>.zip from the project's release page and put it in this folder. "
        + "You can also install it in the IDE from wherever you saved it."
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
