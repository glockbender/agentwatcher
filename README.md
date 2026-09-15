# Agent Watch

[![Verify](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml/badge.svg)](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml)
[![Release](https://img.shields.io/github/v/release/glockbender/agentwatcher?include_prereleases&style=flat-square)](https://github.com/glockbender/agentwatcher/releases)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-blue?style=flat-square)](#build-from-source)

A small macOS app that watches the Claude Code and Codex sessions you have running, so you can see
at a glance which one is working, which one is waiting for you, and which one is done.

It lives in the menu bar and draws one floating row per session: the phase as a coloured lamp,
the time since the last event, the session's name and project, and how many activities are open.
Clicking a row brings forward the terminal tab that session runs in. Hovering it opens a card
with everything the row cannot fit.

`⌥⌘W` shows and hides it from wherever you are. That combination is taken system-wide on the first
launch; `Widget Settings…` records a different one, or clears it.

Alpha: it works and is used daily, but what it shows is still moving.

## Install

Requires a Mac with Apple Silicon (ARM64) and macOS 14 or newer.

1. Download `AgentWatch-<version>.zip` from [Releases](https://github.com/glockbender/agentwatcher/releases)
   and unzip it into `/Applications`.
2. Remove the flag macOS puts on everything downloaded:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentWatch.app
   ```

   The step is needed while the app is signed ad-hoc rather than with an Apple Developer ID
   certificate: macOS cannot check who made it, so it refuses to open it.

3. Open `Tooling…` from the menu bar item and install the integration for each agent you use.

Nothing is written to any agent's configuration until you press install there.

## What it writes

| Integration | Where it goes |
|---|---|
| Claude hooks | `~/.claude/skills/agent-watch/` — a plugin of its own. Your `settings.json` hooks are never touched |
| Claude status line | `~/.claude/settings.json`, key `statusLine` — the only place a context percentage exists for Claude. Your own command is kept and still runs, unchanged, through a wrapper |
| Codex hooks | `~/.codex/hooks.json` — a merge into a file that may already have entries. **Codex then asks you to trust each hook, and until you do, none of them fires** |

Two things worth knowing. New Claude hooks reach a session already running only after
`/reload-plugins` or a new session. And when Agent Watch is not running, hooks do nothing and cost
nothing — the agent never waits on it.

Everything the app remembers sits in `~/Library/Application Support/AgentWatch/`: the widget's
settings as a plain `settings.json` you can edit, and the sessions of the last launch so a restart
does not leave the widget empty.

Nothing about your work leaves the machine. The one request the app makes is to GitHub's public API,
to see whether a newer build exists — at launch, and when you ask from the `Updates` menu. It carries
no parameters and nothing about you, not even the version you run, because the comparison happens
here — the one header the app sets names it, `AgentWatch`, where the system would otherwise have
written the version in. The app offers to download and install the update itself, and the launch check can be turned
off in the same menu.

## JetBrains IDE plugin

Optional, and it changes one thing: a click on a row lands on the terminal **tab** a session runs in
rather than on the IDE window.

Download `agent-watch-ide-<version>.zip` from the same release — the plugin carries its own
version number, which is not the app's — then in the IDE: Settings → Plugins → the gear →
Install Plugin from Disk. The Tooling window lists the JetBrains IDEs it finds, opens that page
for the one you pick with the file's path already copied, and can ask an IDE whether the plugin
answers there now.

## Build from source

Needs Apple Silicon, macOS 14+, Swift 6, Xcode 16 and [Task](https://taskfile.dev/). No third-party dependencies.

```sh
task verify   # lint, tests, debug and release builds, app bundle
task run      # run it from the build directory
```

`task build-app` assembles `dist/AgentWatch.app`, and `task release` packages that bundle into a
zip with its checksum. `task plugin` builds the IDE plugin with its own Gradle wrapper, which
fetches everything it needs by itself, and puts the file where the app offers it to IDEs.

Development notes — the local signing certificate, the shared Xcode scheme, what `task verify`
rebuilds — are in [AGENTS.md](AGENTS.md).

## Documentation

The project documents are written in Russian.

- [Architecture](docs/architecture.md) — product boundaries, the event model, the interface, privacy.
- [Implementation plan](docs/implementation-plan.md) — what is done, what is next, what is deferred.
- [Agent integration](docs/agent-integration.md) — how Agent Watch attaches to each agent, where the
  two differ, and the measurements behind it.
- [Distribution](docs/distribution.md) — how a release is built and signed, and what notarization
  would take.
- [Session focus research](docs/session-focus-research.md) — how far a session can be reached from
  outside the terminal it runs in.

## License

MIT — see [LICENSE](LICENSE).
