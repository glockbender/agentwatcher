import Foundation

/// One thing Agent Watch installs into one agent.
///
/// The word is the plan's: an integration is a single thing put into somebody else's tool,
/// with a state and two operations. Naming it lets the menu be a projection of a list of
/// agents rather than a list of agents written out by hand.
public enum ToolingIntegrationKind: Sendable {
    case hooks
    case statusLine
}

/// One integration in one agent — the pair a menu line switches.
public struct ToolingIntegration: Hashable, Sendable {
    public let source: AgentSource
    public let kind: ToolingIntegrationKind

    public init(source: AgentSource, kind: ToolingIntegrationKind) {
        self.source = source
        self.kind = kind
    }
}

/// What each agent can have installed into it.
///
/// This and `ToolingHooks.hooks(for:)` are the whole table. A third agent is two cases in this
/// file and nothing anywhere else — which is what the tooling plan asked for and did not get:
/// the menu named both agents in source, so an agent added here would have been installable
/// and invisible.
public enum ToolingIntegrations {
    public static func kinds(for source: AgentSource) -> [ToolingIntegrationKind] {
        switch source {
        // Only Claude Code has a status line to stand in front of. Codex reports the size of
        // its context window in the transcript, so there is nothing to take over.
        case .claude: [.hooks, .statusLine]
        case .codex: [.hooks]
        }
    }
}

/// The hooks Agent Watch registers with each agent, by the agent's own name for each event.
///
/// A hook is nothing but that name: it is written into the agent's configuration verbatim and
/// read back out of it the same way. Every one of them reports something nothing else can, so
/// a missing one is a fault the app says out loud — there is no optional hook, and that is a
/// decision rather than an omission. See `testNeitherAgentIsAskedForPostToolUse`.
public enum ToolingHooks {
    public static func hooks(for source: AgentSource) -> [String] {
        switch source {
        case .claude:
            [
                "SessionStart",
                "SessionEnd",
                "UserPromptSubmit",
                "Stop",
                "StopFailure",
                "PermissionRequest",
                "PermissionDenied",
                "PreToolUse",
                "PostToolUseFailure",
                "PreCompact",
                "PostCompact",
                "SubagentStart",
                "SubagentStop",
            ]
        case .codex:
            // Every event Codex offers except the one declined above. Kept in step by
            // `testCodexIsAskedForEveryEventCodexOffersAndDeclinesOnlyOnPurpose`, which
            // carries the catalogue: an event this list falls behind on is a fact lost with
            // nothing to report it.
            [
                "SessionStart",
                "SessionEnd",
                "UserPromptSubmit",
                "Stop",
                // Only Codex reports this. For Claude an interrupted turn produces no hook at
                // all and is found by reading the transcript on silence, up to ten seconds
                // later; here it arrives at once.
                "Interrupt",
                "PermissionRequest",
                "PreToolUse",
                "PreCompact",
                "PostCompact",
                "SubagentStart",
                "SubagentStop",
            ]
        }
    }
}

/// The plugin Agent Watch installs into Claude Code to receive its hooks.
///
/// Claude Code loads any folder under `~/.claude/skills/` that carries a
/// `.claude-plugin/plugin.json` manifest — in every project, with no marketplace, no install
/// step and no trust dialog, that last one applying only to project-scoped plugins. So the
/// hooks live in a directory Agent Watch owns outright, and the settings file a person
/// maintains by hand is never written to.
///
/// The cost of the mechanism is worth stating where the code is: a change to these hooks
/// reaches a running session only after `/reload-plugins` or a new session.
public enum ClaudeHookPlugin {
    /// The folder name under `~/.claude/skills/`, and the plugin's own name.
    public static let name = "agent-watch"

    /// The plugin's `.claude-plugin/plugin.json`, which is what makes the folder a plugin
    /// rather than a bare skill.
    public static func manifest() -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string("Reports Claude Code session activity to the Agent Watch widget."),
        ])
    }

    /// The plugin's `hooks/hooks.json`.
    public static func hooksDocument(senderPath: String, hooks: [String]) -> JSONValue {
        ToolingInstallation.addingOurHooks(
            to: .object(["hooks": .object([:])]),
            source: .claude,
            senderPath: senderPath,
            hooks: hooks
        )
    }
}

/// What is known about whether an agent's hook records have ever run.
///
/// Not readable from any configuration: a file says what an agent is asked for, never what it
/// does with it. Codex skips a hook it has not been told to trust, so complete records and a
/// silent agent look identical on disk.
public enum HookDelivery: Equatable, Sendable {
    /// An event has arrived from this agent. Proof, and it does not expire.
    case arrived
    /// Agent Watch installed these records itself and has heard nothing from the agent since.
    case nothingSinceInstall
    /// Nothing is known. The records predate this app keeping track, so silence says nothing
    /// about them — the alternative would be to announce a fault on the first launch of every
    /// setup that already worked.
    case unknown
}

/// How much of Agent Watch is installed in one agent.
public enum ToolingInstallationState: Equatable, Sendable {
    /// Nothing of ours is there.
    case absent
    /// Every hook is registered against a sender that exists, and at least one event has
    /// arrived from this agent.
    case installed
    /// Registered and complete, and not one event has ever arrived from this agent.
    ///
    /// Reading this as `installed` states something nothing has shown. For Codex it is the
    /// ordinary state right after installing: it skips a hook whose definition it has not been
    /// asked to trust, so the records sit there and nothing fires — and a person has no way to
    /// notice, because it looks exactly like an agent nobody used today.
    ///
    /// Only "never", not "not lately". An agent somebody has not opened this week is not a
    /// fault, and saying so would be the nagging this design avoids.
    case unheard
    /// Some hooks are not there.
    ///
    /// They are named rather than counted, in the order the set declares them: "2 of 13
    /// missing" says there is a problem and nothing about which one, and what to do about it
    /// depends on which.
    case incomplete(missing: [String])
    /// Registered, but naming a sender that is no longer there.
    ///
    /// The test is whether the file exists, not whether the path is the one this app would
    /// write today. A development build and an installed bundle both work — the sender only
    /// delivers to a socket — so comparing an entry against "what I would write now" would
    /// call a working setup broken every time a person switched between them.
    case stale(senderPaths: [String])
    /// The file is there and this app cannot read it.
    ///
    /// Deliberately not `absent`, which is what it used to read as. Absent invites installing,
    /// and installing writes — over a file whose contents nobody can state. The two look the
    /// same to a reader and are opposites to a writer, which is the whole reason this case
    /// exists rather than being folded into the one beside it.
    case unreadable

    /// Whether the one thing a person can do to this is install rather than remove.
    ///
    /// Installing over a broken installation repairs it — our entries are replaced, not
    /// repeated — whereas removing it would make a person press twice to fix one problem. The
    /// two states that do not want it are a whole installation, which offers to be taken
    /// away, and one nobody can read, where writing is the one thing that must not happen.
    public var wantsInstalling: Bool {
        switch self {
        case .absent, .incomplete, .stale: true
        // `unheard` is complete, so installing it again writes the same file and changes
        // nothing. What it needs is elsewhere — in Codex, approving what is already there.
        case .installed, .unheard, .unreadable: false
        }
    }
}

/// Reading an agent's hook configuration back: what Agent Watch has registered there, and
/// against which sender.
///
/// Everything here works on already-parsed JSON and never opens a file, so the rules that
/// decide whether an installation is whole are checkable without a disk — and so the same
/// rules serve both places hooks can live, the plugin Agent Watch owns and the settings file
/// it only ever removes from.
public enum ToolingInstallation {
    /// The sender each event is registered against, for entries Agent Watch would have
    /// written.
    ///
    /// Anything else in the document belongs to someone else: not counted, not reported on,
    /// and never removed. An entry is recognised by the shape of the command the app writes,
    /// not by a marker of its own — a marker would have to survive in a file the app does not
    /// control, and the command is already unambiguous.
    public static func senderPaths(inHooks document: JSONValue, source: AgentSource) -> [String: String] {
        guard case let .object(root) = document, case let .object(events)? = root["hooks"] else {
            return [:]
        }

        var paths: [String: String] = [:]
        for (event, groups) in events {
            guard case let .array(groupList) = groups else {
                continue
            }
            for group in groupList {
                guard
                    case let .object(groupFields) = group,
                    case let .array(entries)? = groupFields["hooks"]
                else {
                    continue
                }
                for entry in entries {
                    guard
                        case let .object(fields) = entry,
                        case let .string(command)? = fields["command"],
                        let path = senderPath(inCommand: command, source: source, event: event)
                    else {
                        continue
                    }
                    paths[event] = path
                }
            }
        }
        return paths
    }

    /// How long an agent waits for one hook before giving up on it.
    ///
    /// Generous because the cost of a hook is starting a process, not the work it does. On a
    /// machine whose security agent authorises every launch that alone measured 0.78 s, while
    /// the sender's own work is 5–12 ms — so a tight timeout would kill hooks that were never
    /// slow, only expensive to start.
    public static let hookTimeoutSeconds = 3

    /// The same document with Agent Watch's own hook entries in it.
    ///
    /// Ours are added beside whatever is already there, and running it again changes nothing:
    /// a person may press install twice, and an installer that grew the file each time would
    /// fire every hook twice, then three times.
    public static func addingOurHooks(
        to document: JSONValue,
        source: AgentSource,
        senderPath: String,
        hooks: [String]
    ) -> JSONValue {
        // Ours come out first, so a second run replaces rather than repeats — and so a
        // reinstall after the sender moved rewrites the path instead of adding a second entry.
        guard case var .object(root) = removingOurHooks(from: document, source: source) else {
            return document
        }
        var events: [String: JSONValue] = {
            if case let .object(existing)? = root["hooks"] { existing } else { [:] }
        }()

        for event in hooks {
            let entry = JSONValue.object([
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        // Quoted, because a shell runs this and the sender's own directory
                        // has a space in its name. See `ShellWord`.
                        "command": .string(
                            "\(ShellWord.quoted(senderPath)) --source \(source.rawValue) --event \(event)"
                        ),
                        "timeout": .number(Double(hookTimeoutSeconds)),
                    ])
                ])
            ])
            if case let .array(groups)? = events[event] {
                events[event] = .array(groups + [entry])
            } else {
                events[event] = .array([entry])
            }
        }

        root["hooks"] = .object(events)
        return .object(root)
    }

    /// The same document with Agent Watch's own hook entries taken out.
    ///
    /// One-way on purpose. This is the settings file a person maintains by hand, and the app
    /// never adds to it — hooks go into a plugin of our own instead. It only removes, and
    /// only what it can recognise as its own, because entries registered before the plugin
    /// existed would otherwise fire alongside it and double a cost that is already the
    /// expensive part of a hook.
    ///
    /// A group left with no entries goes, and an event left with no groups goes with it: an
    /// empty key left behind is litter in someone else's file.
    public static func removingOurHooks(from document: JSONValue, source: AgentSource) -> JSONValue {
        guard case var .object(root) = document, case let .object(events)? = root["hooks"] else {
            return document
        }

        var remaining: [String: JSONValue] = [:]
        for (event, groups) in events {
            guard case let .array(groupList) = groups else {
                remaining[event] = groups
                continue
            }
            let keptGroups: [JSONValue] = groupList.compactMap { group in
                guard
                    case var .object(groupFields) = group,
                    case let .array(entries)? = groupFields["hooks"]
                else {
                    return group
                }
                let kept = entries.filter { entry in
                    guard
                        case let .object(fields) = entry,
                        case let .string(command)? = fields["command"]
                    else {
                        return true
                    }
                    return senderPath(inCommand: command, source: source, event: event) == nil
                }
                guard !kept.isEmpty else {
                    return nil
                }
                groupFields["hooks"] = .array(kept)
                return .object(groupFields)
            }
            if !keptGroups.isEmpty {
                remaining[event] = .array(keptGroups)
            }
        }

        if remaining.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = .object(remaining)
        }
        return .object(root)
    }

    /// The sender a command names, if the command is one Agent Watch writes for this event.
    ///
    /// Unquoted on the way out, so an entry written before the path was quoted is still read
    /// as ours — otherwise a reinstall would leave it in place and add its own beside it, and
    /// every hook would fire twice.
    private static func senderPath(inCommand command: String, source: AgentSource, event: String) -> String? {
        let suffix = " --source \(source.rawValue) --event \(event)"
        guard command.hasSuffix(suffix) else {
            return nil
        }
        return ShellWord.unquoted(String(command.dropLast(suffix.count)))
    }

    /// What a reading means.
    public static func state(
        senderPaths: [String: String],
        hooks: [String],
        senderExists: (String) -> Bool,
        delivery: HookDelivery
    ) -> ToolingInstallationState {
        guard !senderPaths.isEmpty else {
            return .absent
        }
        // Ahead of anything about completeness: an entry naming a sender that is gone does
        // not run at all, so how many of them there are is beside the point.
        let gone = Set(senderPaths.values.filter { !senderExists($0) }).sorted()
        guard gone.isEmpty else {
            return .stale(senderPaths: gone)
        }

        let missing = hooks.filter { senderPaths[$0] == nil }
        guard missing.isEmpty else {
            return .incomplete(missing: missing)
        }
        // Last, because it is the only one of these that writing the file again cannot fix.
        // Missing records are repaired by installing; records that have never delivered need
        // something a person does elsewhere, and offering a repair here would be a wrong turn.
        return delivery == .nothingSinceInstall ? .unheard : .installed
    }
}
