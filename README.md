# Agent Watch

[![Verify](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml/badge.svg)](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-blue?style=flat-square)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square)](https://www.swift.org/)
[![Status](https://img.shields.io/badge/Status-alpha-yellow?style=flat-square)](docs/implementation-plan.md)

Agent Watch is a lightweight, AppKit-first macOS application for monitoring parallel Claude Code and
Codex sessions.

This repository currently contains the local development scaffold: a menu bar application, a
non-activating floating panel, a testable domain model for session phases and parallel activities,
and reproducible build, test, lint, and app-bundling commands.

It also contains the working local alpha: a Unix-socket ingress and a fail-open hook sender bring
Claude Code and Codex lifecycle events into the HUD, and the sessions of one launch are still there
after the next one starts. Plugin distribution, local statistics, hang diagnostics, and local LLM
features remain later stages.

## Install

Builds are published on the repository's [Releases](https://github.com/glockbender/agentwatcher/releases)
page as `AgentWatch-<version>.zip`. Unzip it into `/Applications`, then remove the flag macOS puts
on everything downloaded:

```sh
xattr -dr com.apple.quarantine /Applications/AgentWatch.app
```

The step is needed while the app is signed ad-hoc rather than with an Apple Developer ID
certificate: macOS cannot check who made it, so it refuses to open it. The measurement behind that
sentence, and what notarization would take, are in [Distribution](docs/distribution.md).

To build it yourself instead, follow Quick start below.

## Requirements

- macOS 14 or newer;
- Swift 6.0 or newer;
- Xcode 16 or newer for the full test and verification workflow;
- Apple Command Line Tools are sufficient for formatting and building the app shell;
- [Task](https://taskfile.dev/) for the convenience commands below.

The project has no third-party runtime dependencies. Formatting and linting use `swift format`,
bundled with the installed Swift toolchain.

The JetBrains IDE plugin in `ide-plugin/` is the one part built with something else, and only
if you build it. It needs nothing installed: `./gradlew` fetches Gradle, and the build fetches
its own JDK 21 — both into Gradle's cache, not onto the machine. It is not part of
`task verify` and the Swift build never looks at it. It compiles against a JetBrains IDE
already installed on the machine rather than one Gradle downloads.

`task plugin` builds and tests it, and its `stagePlugin` step copies the zip the packaging task
produced into `~/Library/Application Support/AgentWatch/ide-plugin/` — the folder the app offers to
the IDEs it finds, in the Tooling window's IDE integrations section. The app knows only that folder: a release
downloaded there later looks the same to it as a build put there now.

`cd ide-plugin && ./gradlew verifyPlugin` additionally runs the
IntelliJ Plugin Verifier against that same installed IDE, which is the only check that says whether
every platform class the plugin references is reachable at runtime. Run it when the set of platform
classes used changes, and before publishing.

## Quick start

```sh
task doctor
task verify
task run
```

If Xcode is installed but `xcode-select -p` still points to `/Library/Developer/CommandLineTools`,
run the verification without changing the system-wide selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer task verify
```

`task run` starts the development executable. The app appears in the menu bar and opens a small
floating panel.

### Widget settings

`Widget Settings…` opens a window for how the widget looks: one row per session phase with
its own colour and motion, the background palette, and the opacity. Each row's tooltip says when
that phase happens. Every control takes effect at once — the widget is on screen while the window
is open — and `Use the app's own lamp` forgets every colour and motion chosen there.

The menu bar item also carries two submenus. `Read Session Transcripts` is described below;
`Widget Behavior` holds how the widget behaves rather than how it looks:

| Setting | Default | Effect |
|---|---|---|
| `Lock Position` | off | The widget cannot be dragged, so a stray click cannot move it |
| `Lock Size` | off | The widget cannot be resized by hand |
| `Reset Widget Position` | — | Brings the widget back to the middle of the main screen, even while the position is locked |
| `Reset Widget Size` | — | Returns the widget to sizing itself from the number of sessions |
| `Closed Sessions` | remove after 2 minutes | How long a finished session stays visible before it retires itself: 2 minutes, 10 minutes, or keep until dismissed |
| `Show Session Topic` | on | Shows each session's own name in its row and on its hover card. The sender reads the name either way, so this only stops it being displayed |

### Tooling

Agent Watch has to be installed into each agent before it can see anything. The `Tooling…` menu
item opens a window that shows how far it got and is where each integration is switched on or off.
Every row is the state, the reason and the button for one integration. What each agent needs, where
the two differ, and why — `docs/agent-integration.md`.

| Integration | Where it goes | Notes |
|---|---|---|
| Claude hooks | `~/.claude/skills/agent-watch/` | A plugin Agent Watch owns. Claude Code loads any folder there that carries a `.claude-plugin/plugin.json` manifest, in every project, with no marketplace and no install step. Your `settings.json` is never written to |
| Claude status line | `~/.claude/settings.json`, key `statusLine` | The only source of a context percentage for Claude. Your own command is kept and still runs — see below |
| Codex hooks | `~/.codex/hooks.json` | Codex plugins cannot carry hooks — the feature was removed — so this is a merge into its own file. Anything else in it keeps its place. **Codex then asks you to trust each hook, and until you do, none of them fires** |

One thing worth knowing: **new Claude hooks reach a running session only after
`/reload-plugins` or a new session.** A plugin Claude Code has already loaded does not pick
them up by itself.

If you ever registered these hooks in `settings.json` by hand, take them out yourself once —
they keep firing beside the plugin, and each one costs a process launch. Agent Watch does not
touch the `hooks` key there at all; `statusLine` is the only key it ever writes.

Every hook is required, and `PostToolUse` is not among them. Its one job is closing an
activity, which two other things already do: the transcript reader turns a `tool_result`
record into the same fact, and the end of a turn sweeps every activity that does not outlive
it. So the hook buys freshness, not facts — and charges a process launch per tool call for it,
which measured 0.78 s on the machine this was tested on. If you installed the hooks with an
earlier version, reinstall them once so that entry goes away.

The widget asks for exactly one thing: that some agent can report to it. With none installed
it says so instead of sitting empty. With one, it never mentions the others — running only
Claude on a machine that also has Codex is a decision, not a half-finished setup.

#### The status line

Claude Code allows one status-line command and it is usually already taken, yet its payload is
the only place a context percentage for Claude exists. Agent Watch never edits your script.
It writes its own at `~/Library/Application Support/AgentWatch/statusline-relay.sh`, which
hands a copy of the payload to Agent Watch in the background and then runs your command
unchanged — your output, your exit code. A copy of your command sits in plain text beside the
script. If Agent Watch is stopped, removed or broken, your status line still works.

### Reading session transcripts

Hooks report a tool call ending only when it succeeded. A call a person stopped, and the real end of
a background command, are reported by nothing — so the app also reads the tail of each working
session's own transcript, as a second source beside the hooks rather than instead of them. `Read
Session Transcripts` sets the ceiling on how often (at most every 3, 5 or 10 seconds, default 5) or
turns it off — a hook pulls the next read towards itself, half a second after it, and a read happens
anyway within twice the chosen interval; turning it off leaves the hooks running and loses only
those endings. The reading happens off the main thread, and only while some session claims to be
working.

The reader also takes what a session says about itself: the model it runs on — the one signal both
agents write into their own file — and, for Codex, the size of its context, the branch it started on
and whether the thread is a person's or an agent's. Codex reports none of that through a hook, so
before this a Codex row showed a name and a phase where a Claude row showed a context size and a
branch. The context percentage is computed only for Codex, because only there do the count and the
window come from one record; a count read from a transcript never wears a percentage measured
somewhere else.

Only seven kinds of record are looked at, out of the fourteen a transcript holds. Every other line
is walked past by shape, so prompts, command output and file contents pass through a parse and are
dropped. Of what the reader does take, only the few fields listed under "After a restart" are ever
written down. The app finds the file by hashing file names rather than being told a path, so no new
field crosses the socket — see `docs/architecture.md` §15.

Failures are shown rather than absorbed. A row carries an amber triangle, its hover card says what
is wrong in words, the Event Debug window carries the line, the top of the transcript submenu
summarises it, and the row can be dismissed straight away — every other row waits out a threshold
before offering that, because until then the app still believes what it says. Four things are
reported: no transcript found for a session (after thirty seconds, since the file appears only when
the agent first writes to it), a transcript that cannot be read, an increment too large to be real —
where the reader skips to the end and loses what was in between — and silence nothing accounts for,
meaning the session claims to be working, no call is open, its transcript has stopped growing, and
neither source has said anything for two minutes. A turn that only thinks writes lines this reader
takes nothing from, and those lines still count as hearing it. None of them changes what the row
says the session is doing; they say how much of it is still known.

The widget sizes itself to the number of sessions, up to eight rows, and scrolls beyond that.
Resizing it by hand fixes the size for good: from then on the list scrolls rather than the window
growing, until `Reset Widget Size`.

A row reads `[focus] [timer] [lamp] [icons] [name] [counts] [dismiss]`, in that order in every row,
so the columns line up down the list. The lamp is the phase: colour for which phase, motion for what
it means — a slow pulse for work, a fast blink for a session waiting on you, a steady dot for one at
rest, a ring for one that has closed. The timer is time since the last event in three characters,
and its colour is what a `no fresh activity` suffix used to say in words. Source and client are the
real Claude and Codex application icons plus a terminal or window symbol. The two client symbols
differ in fill as well as colour — a solid terminal against an outlined window — because at row size
two outlined rectangles in the same grey were one picture drawn twice. The name shortens in the
middle when there is not enough room, and falls back to a first letter when there is almost none.

Hovering a row highlights it at once and, half a second later, opens a card with everything the row
cannot fit: the whole name, the source, the client, the phase in words, the project and its git
branch, how long ago the last event was, the running activities named rather than counted, and the
size of the context. Along the widget's border the strip under the pointer lights up, so a drag that
resizes is never mistaken for a drag that moves. It is drawn rather than shown as a resize cursor
because macOS shows that cursor only over the window holding keyboard focus, and this widget refuses
focus so that clicking it never takes the keyboard away from the window being worked in.

Rows keep the order their sessions appeared in and do not move; only a closed session sinks to the
bottom while it waits to be removed.

To produce a local `.app` bundle:

```sh
task build-app
open dist/AgentWatch.app
```

The bundle is built in the release configuration, because it is the one a person installs and
runs: the debug configuration also compiles in the menu items that write raw hook payloads to
disk. Pass `debug` to `./scripts/build-app.sh` when you want those.

`dist/` is rebuilt from scratch by every `task verify`, so the hooks the Tooling window registers
should not point into it. Copy the bundle somewhere it will stay — `cp -R dist/AgentWatch.app
/Applications/` — and install the integrations from the copy.

The local bundle is ad-hoc signed. Distribution signing and notarization intentionally remain
outside the initial local-only scaffold.

When Xcode is installed, open `Package.swift` directly. Swift Package Manager remains the source of
truth, so no generated `.xcodeproj` is committed at this stage.

One Agent Watch runs at a time, so quit an installed copy before running your own build:

```sh
osascript -e 'quit app "AgentWatch"'
```

The repository ships one shared scheme, `.swiftpm/xcode/xcshareddata/xcschemes/AgentWatch.xcscheme`,
and it is there for a single reason: Xcode builds only the products a scheme names, and
`AgentWatchSend` is a product of its own. The generated scheme built the app alone, leaving no
sender beside it — so installing the hooks from Xcode wrote a path to a file that did not exist.
This scheme builds both.

### Where the settings live

Everything Agent Watch remembers between launches sits in one folder,
`~/Library/Application Support/AgentWatch/`. The widget's own settings are `settings.json` there —
a flat JSON object you can read, correct by hand and copy to another machine. A hand edit takes
effect on the next launch: a running app keeps its own copy and does not read the file again.

The file describes the widget completely rather than by absence. Every launch writes out whatever
it does not already hold, so a fresh install finds the whole configuration in it, and a version
that adds a setting fills in that one key without touching anything you have chosen. `Use the app's
own lamp` writes the defaults back rather than removing the keys.

`widgetSizeFollowsSessions` is why the size is a setting like any other. While it is on, the widget
fits its height to the number of sessions; dragging an edge turns it off and records the size you
chose, and `Reset Widget Size` turns it back on at the size a fresh install has. The one key nothing
writes at launch is the position — where the widget goes depends on your screens, so it is written
the moment the widget is first placed.

A file written before that key existed is read the way the version that wrote it meant: back then a
size in the file *was* how the widget said it had been resized by hand, so a size with no key beside
it turns following off rather than on. Otherwise the launch that adds the key would hand every
hand-sized widget back to the session count while the file went on naming a size nothing applied.

Not `UserDefaults`, for a measured reason. The preference domain a process writes to depends on how
it was launched: a bundled copy uses its bundle identifier, a bare `swift build` executable uses its
own file name, and an identifier that changes once leaves a third domain behind. Three of them had
collected on the development machine, each with a different background, opacity and widget frame, so
a setting chosen in one build was invisible to the other and the widget moved and resized on every
switch. The folder above is the one thing every build shares.

### After a restart

Agent Watch learns of a session from a hook, so a restart used to leave the widget empty until every
session happened to do something next — which for a session waiting on a person is never. The
sessions that were still open are now kept in
`~/Library/Application Support/AgentWatch/sessions-remembered.json`, and a launch brings back the
ones something can still vouch for: a session in the Codex app is vouched for by that app running,
everything else by its own process, checked against the session's last event because macOS reuses
process numbers. A session whose agent is gone is not brought back and is forgotten.

A restored row says `no signal`. It carries the project, branch, model and context it had, but no
open call and no warning: what a session is doing is what its first real hook says. One phase is the
exception — a session remembered waiting for you comes back waiting, but only once its own
transcript agrees that the wait still holds, since no second hook announces a wait. The age on the row comes from its transcript's own last write, which for a session nobody
was watching is the only record of the time that passed.

With `Read Session Transcripts` turned off, that catch-up does not happen either — the setting is
about the file and not about the timer, so a launch is no exception to it. The age then comes from
the memory alone, and a session remembered waiting for you stays at `no signal`, since the only
evidence that the wait still holds is the one file nobody is reading.

The file holds the hashed session label, the agent, the row's position, the session name, the
project name, the branch, the mode, the model, the context size, the agent's process id and the time
it was last heard from — plus the one wait it keeps, as the awaited call's id and the kind of
request. Beside the sessions it keeps a second list: which running process is which session, as one
of that session's hooks once said, so a process found again after its row is gone is recognised
rather than shown as a nameless row. No commands, no paths, no conversation.

## Quality commands

| Command | Purpose |
|---|---|
| `task format` | Format Swift files with the repository configuration |
| `task lint` | Fail on formatting and style findings |
| `task test` | Run unit tests with warnings as errors |
| `task build` | Build all targets with warnings as errors |
| `task build-app` | Assemble a local app bundle in the release configuration (see signing below) |
| `task build-sender` | Build the fail-open Unix-socket hook sender |
| `task verify` | Run lint, tests, debug and release builds, and the app bundle build |
| `task plugin` | Build and test the JetBrains IDE plugin, and stage the zip for installing |
| `task release` | Package the app bundle into a release zip and its checksum |
| `task setup` | Enable the repository-local pre-commit hook |

### Packaging a release

`task release` builds the bundle in the release configuration and writes
`dist/AgentWatch-<version>.zip` and its `.sha256` beside it. The version comes from
`CFBundleShortVersionString` in `Resources/Info.plist`, which is the single place it is written.

It does **not** use the local certificate below. A release is signed with the identity named in
`AGENT_WATCH_RELEASE_IDENTITY`, and ad-hoc with a warning when that is unset — a self-signed
certificate that exists only on the machine that built the app means nothing to anybody who
downloads it.

Pushing a tag `vX.Y.Z` runs the same packaging in CI and leaves a draft release with both files
attached. The tag has to match the version in `Info.plist`, or the job stops before building.
See [Distribution](docs/distribution.md).

### Signing the local bundle

`build-app.sh` signs with a certificate called **Agent Watch Developer** when the keychain has
one, and falls back to an ad-hoc signature with a warning when it does not. Pass
`AGENT_WATCH_SIGNING_IDENTITY` to use a different one.

The certificate is not about distribution. An ad-hoc signature makes the bundle's designated
requirement a hash of the binary, and that hash changes on a rebuild with no source change at
all — while macOS keeps every permission next to the requirement of whoever was granted it. So
under an ad-hoc signature every Accessibility, Automation and Screen Recording permission this
app is given is lost on the next build, and a feature that needs one cannot be tried even on
the machine that built it. A certificate replaces the hash with the certificate's own identity,
which rebuilds do not change. Self-signed is enough; Developer ID is for handing the app to
other people.

To create one, open Keychain Access — since macOS 15 it is no longer in Utilities:

```sh
open "/System/Library/CoreServices/Applications/Keychain Access.app"
```

Then menu **Keychain Access → Certificate Assistant → Create a Certificate…**, name it
`Agent Watch Developer`, set Identity Type to **Self Signed Root** and Certificate Type to
**Code Signing**, then Create. Leave the override checkbox off. The first build afterwards asks
for access to the key: answer **Always Allow**, or the prompt returns on every build and hangs
`task verify` with no explanation.

The certificate does **not** need to be marked trusted. `security find-identity -v` will not
list it — `-v` keeps only trusted identities, and a self-signed root is untrusted until
somebody says otherwise — but trust governs verifying a signature, not making one, and
`codesign` signs with it happily. The build script looks it up without `-v` for exactly this
reason.

To check that it took, build twice and compare:

```sh
task build-app && codesign -d -r- dist/AgentWatch.app 2>&1 | grep designated
```

Signed with a certificate the line names the certificate and stays the same across builds;
ad-hoc it is a `cdhash` that differs every time.

## Project structure

```text
Sources/
├── AgentWatchApp/       AppKit lifecycle and UI shell
├── AgentWatchCore/      AppKit-free session and activity domain
├── AgentWatchIngress/   Local Unix-socket ingress
├── AgentWatchSend/      Fail-open hook sender CLI
└── AgentWatchSender/    Sender transport, agent-process lookup, session-title resolution
Tests/
├── AgentWatchAppTests/  Local runtime and AppKit-adjacent tests
├── AgentWatchCoreTests/ Deterministic state transition tests
└── AgentWatchIngressTests/ Socket transport and sender-side tests
Fixtures/
└── HookPayloads/       Anonymized hook-capture fixtures
Resources/
└── Info.plist           Local app bundle metadata
ide-plugin/
└── src/main/kotlin/     JetBrains IDE plugin: brings a session's terminal tab forward
scripts/
└── build-app.sh         Reproducible local .app assembly
docs/
├── architecture.md          Product and target architecture
├── agent-integration.md     What each agent reports, and how Agent Watch attaches to it
├── distribution.md          Packaging and delivery
├── session-focus-research.md  How far a session can be reached from outside
└── implementation-plan.md   Current milestones and acceptance criteria
.github/workflows/
└── verify.yml           CI running the same `task verify` gate
```

## Documentation

- [Architecture and product article](docs/architecture.md) explains the product boundaries, data
  model, UI principles, and the long-term role of local LLMs.
- [Implementation plan](docs/implementation-plan.md) is the current source of truth for completed
  work, next milestones, and deferred decisions.
- [Agent integration](docs/agent-integration.md) holds the differences between Claude Code and
  Codex, the events each one sends, and the measurements behind them.
- [Distribution](docs/distribution.md) covers packaging and delivery.
- [Session focus research](docs/session-focus-research.md) records how far a session can be reached
  from outside the terminal it runs in.

The current focus is dogfooding the lifecycle HUD. Its hooks now install as a Claude Code plugin
from the app's own Tooling window; potential-hang detection, persistent storage, and plugin
distribution remain separate stages.

## Debug raw hook capture

The debug build can temporarily record the original hook payloads for investigating an
integration mismatch. Enable **Record Raw Hook Payloads for 30 Minutes** from the
Agent Watch menu. The sender stops recording after that deadline even if the app has
been closed. The files live in `~/Library/Application Support/AgentWatch/debug-hook-capture/`.

Stopping the recording does not delete what was already recorded — stopping is what you do
in order to read it. **Delete Recorded Payloads** in the same menu removes those files and
shows how much is there; it is hidden when nothing is.

This is deliberately separate from Event Debug: Event Debug contains compact,
redacted normalized events, while raw capture can contain prompts, commands, paths,
and other sensitive hook fields. It is compiled only into debug builds, is off by
default, is local-only, and uses a five-file JSONL ring capped at 10 MiB. Do not share
the raw files without reviewing their contents.

One record is one line, so a payload whose outer whitespace holds a newline is trimmed and
one with a newline inside is dropped rather than written across two lines. The hook hands
the bytes to a second process that does the writing, and that process starts only after the
event itself has been sent. In a debug build `AGENT_WATCH_DEBUG_CAPTURE_DIR` moves the whole
capture — switch, lock and segments — somewhere else, which is how the end-to-end test drives
it without touching the real directory.

## Local sender

`AgentWatchSend` is the fail-open hook sender for the local socket ingress. It ships beside the app
in the bundle, and the Tooling window registers hooks against it. It reads one JSON object from
standard input, wraps it with the declared source and hook name, and has a 100 ms connection/write
deadline. It emits no payload, error, or diagnostic text. When Agent Watch is not running, the hook
continues normally and the event is intentionally dropped.

```sh
task build-sender
printf '%s\n' '{"session_id":"example"}' \
  | .build/debug/AgentWatchSend --source claude --event SessionStart
```

One Agent Watch runs at a time. It owns `~/Library/Application Support/AgentWatch/agent-watch.sock`
with owner-only permissions, held by a lock beside it; a launch that cannot take the lock asks the
running instance to show itself and exits. Without `--socket`, `AgentWatchSend` delivers one
already-redacted event to that socket under a 100 ms deadline. An explicit `--socket` retains
point-to-point delivery for smoke tests. The socket protocol is versioned
(`HookIngressRequest.schemaVersion`); distributing the app itself is the next step.

## Git

The default branch is `main`. Run `task setup` once to enable the local pre-commit quality gate.

CI runs the same gate: `.github/workflows/verify.yml` installs Task on a macOS runner and calls
`task verify`, so the check that blocks a commit and the check that colours the badge are one
command, not two lists that can drift apart.
