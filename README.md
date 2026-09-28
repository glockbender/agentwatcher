# Agent Watch

[![Verify](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml/badge.svg)](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml)
[![Release](https://img.shields.io/github/v/release/glockbender/agentwatcher?include_prereleases&style=flat-square)](https://github.com/glockbender/agentwatcher/releases)

**See which Claude Code or Codex session needs you — without switching between terminals.**

Agent Watch is a small menu bar app for **Apple Silicon Macs running macOS 14+**.
Its floating widget shows your sessions together. Click a row to return to the session;
hover for details.

<img src="docs/images/widget.png" alt="Five sessions in a compact blue Agent Watch widget" width="339">

## How it works

Start a request in your agent. Watch its row change as it works, asks for input, and finishes.
The other sessions keep their own states, so you can see where to turn next.

<img src="docs/images/widget-demo.gif" alt="Different lamp rhythms; Catalog moves from inactive to active, asks for an answer, finishes and becomes inactive again" width="339">

Watch **Catalog** move up from inactive to active, ask for an answer, finish, and return below
active work. Green pulses slowly; orange alternates with yellow quickly when you need to answer.
These are real widget views and lamp timings with fictional sessions.
The 20-second loop demonstrates behavior; it is not a recording of agent work.
Clicking a row activates its host; exact tab selection is available in Ghostty and in JetBrains IDEs
with the optional plugin below.

**Alpha:** used daily, still being refined. The steps below are for the current download, `0.1.0`.
The images show the next release; what it adds is listed under *Coming in the next release*.

## Install and connect

1. Download `AgentWatch-<version>.zip` from [Releases](https://github.com/glockbender/agentwatcher/releases)
   and unzip the app into `/Applications`.
2. Current alpha builds have an ad-hoc signature. After downloading from this project's release,
   remove the quarantine flag so macOS can open the app:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentWatch.app
   ```

3. Open Agent Watch, choose **Tooling…** in the menu bar, and press **Install** on the Hooks row
   of each agent you use.
4. **Claude Code:** run `/reload-plugins` in an existing session, or start a new session.
   **Codex:** accept its trust prompts for the hooks. Then send a short request.
5. The session appears in the widget.

Nothing is written to an agent's configuration until you press an installation button.
Claude's optional status line (**Connect** in Tooling) adds context and account usage; your
existing status-line command is kept. You can connect just one agent.

### Coming in the next release

- **Guided setup.** The empty widget offers **Connect Agent →**. The guide helps you choose
  Claude Code or Codex, press **Install Connection**, and then waits for the agent's first signal.
  **Tooling → Set Up Again…** repeats it without deleting sessions, changing appearance or
  removing integrations.
- **Program markers.** Tooling shows whether each agent's program was found, separately from
  whether it is connected. “Not found” only means that the executable is not in the usual
  locations; you can still connect an agent installed elsewhere.
- **Row order and a shortcut.** Widget Settings chooses how rows are ordered (the demo above uses
  **By blocks**; `0.1.0` keeps arrival order) and a global shortcut, `⌥⌘W` by default.
- **A blue default palette.** The images on this page use it; `0.1.0` starts with Graphite.
- **A shorter menu.** Sessions are listed at the top; settings, **Tooling…** included, move under
  **Settings**.
- **Updates from the app.** It checks GitHub for a newer release at launch and installs one when
  you ask. **Settings → Updates** turns the launch check off.

<details>
<summary>See the connection guide</summary>

<img src="docs/images/setup-connect.png" alt="Guided connection setup highlights the install button, explains local signals and offers the optional Claude status line" width="480">

</details>

## JetBrains IDE plugin

The optional plugin takes a widget click to the **exact terminal tab** in your IDE.
It supports classic and reworked terminals; the declared minimum is JetBrains platform 2025.1.
It needs the Agent Watch macOS app and does nothing on its own.

1. Download `agent-watch-ide-<version>.zip` from the same [release page](https://github.com/glockbender/agentwatcher/releases).
   The plugin has its own version number.
2. In the IDE: **Settings → Plugins → gear → Install Plugin from Disk**. Select the ZIP.
   Restart if the IDE asks you to.
3. With the IDE running, open Agent Watch's **Tooling…** and press **Check** beside it.
4. Start an agent in that IDE's terminal and click its widget row to check the jump.

Marketplace publication is still part of the [release plan](docs/release-plan.md).
The app does not download the plugin for you yet, so install the ZIP from disk as above.

## If no session appears

- **Installed, waiting for a signal:** reload Claude's plugin or accept Codex's hook trust prompts,
  then send a request. Installation alone does not prove delivery.
- **Connection needs repair:** open Tooling and use its repair action. Unreadable configuration is
  left alone, with an explanation of what needs attention.
- Use **Remove** or **Disconnect** in Tooling to undo an integration.

## Local by default

Session monitoring stays on your Mac. Hooks send local events and fail open when Agent Watch
is not running. Settings and remembered sessions live in
`~/Library/Application Support/AgentWatch/`.
See [agent integration](docs/agent-integration.md) for the files it writes and
[architecture](docs/architecture.md) for the privacy boundaries.

## Build from source

Requires Swift 6, Xcode 16 and [Task](https://taskfile.dev/).

```sh
task verify   # formatting, tests, debug/release builds and app bundle
task run      # run the app
```

`task plugin` builds the IDE plugin and places it where Tooling's **Open Plugins** finds it.
Development details are in [AGENTS.md](AGENTS.md).

## Documentation

Project documents are in Russian:

- [Release plan](docs/release-plan.md) — remaining blockers, plugin publication and acceptance checks.
- [Architecture](docs/architecture.md) · [Implementation plan](docs/implementation-plan.md)
- [Agent integration](docs/agent-integration.md) · [Distribution](docs/distribution.md)

MIT — see [LICENSE](LICENSE).
