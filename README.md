# Agent Watch

[![Verify](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml/badge.svg)](https://github.com/glockbender/agentwatcher/actions/workflows/verify.yml)
[![Release](https://img.shields.io/github/v/release/glockbender/agentwatcher?include_prereleases&style=flat-square)](https://github.com/glockbender/agentwatcher/releases)

**See which Claude Code or Codex session needs you, without switching between terminals.**

A menu bar app for Apple Silicon Macs with macOS 14 or newer. Alpha: used every day, still changing.
[Download](https://github.com/glockbender/agentwatcher/releases) · [Install](#install) ·
[Troubleshooting](TROUBLESHOOTING.md)

<img src="docs/images/clip-hero.avif" alt="A session waits for approval; a click on its row in the widget opens its terminal tab at the question, and once answered the row turns done" width="800">

<img src="docs/images/widget.png" alt="The widget with seven sessions: two need you, three are working, one is done and one is quiet" width="380">

Every agent session is one row in a small floating widget. The lamp at the start of a row says
what the session is doing, so one look tells you where you are needed. Click a row to go back
to that session's terminal tab; hover it for details. `⌥⌘W` shows or hides the widget. Without
the widget, the menu bar lists the same sessions and does the same.

## What the lamps mean

<img src="docs/images/lamps.gif" alt="One row per lamp, each blinking at its real speed: working, planning, waiting for a subagent, needs your answer, done, started, failed, usage limit reached, no signal, terminal closed, closed" width="324">

The lamps fall into the four groups the menu bar counts:

| Group | Lamps |
|---|---|
| **Needs you** | Orange and yellow, alternating fast: a permission, a choice or a question. Red: failed, or the terminal was closed and the agent stayed behind |
| **Working** | Green pulse: working. Cyan: planning. Light blue: the turn is over, a subagent still works |
| **Done** | Steady light grey: the last turn finished |
| **Idle** | Grey: started, nothing asked yet. Ring: no signal for a while. Pause sign: usage limit reached |

A black ring means the session closed; it leaves the list after the time set in **Settings… →
General**. Colour is never the only sign: the ring, the pause sign and the menu's marks differ by
shape.

<details>
<summary>Hover a row for its details</summary>

<img src="docs/images/card.png" alt="Hover card: name, agent, model, project and branch, last event, running work and context size" width="231">

</details>

## Install

> [!NOTE]
> Alpha builds are signed ad hoc, not with an Apple Developer ID, so macOS blocks them until
> step 2 below.

1. Download `AgentWatch-<version>.dmg` from [Releases](https://github.com/glockbender/agentwatcher/releases),
   open it and drag Agent Watch to Applications.
2. Remove the quarantine flag, so macOS lets the app open:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentWatch.app
   ```

   **System Settings → Privacy & Security → Open Anyway** also exists, but does not work on every
   Mac for such apps; the command above always does.

3. Open Agent Watch. The empty widget offers **Connect Agent →**. Choose Claude Code or Codex
   and press **Install Connection**.
4. **Claude Code:** run `/reload-plugins` in a running session, or start a new one.
   **Codex:** accept its trust prompt for the hooks. Then send a short request; the session
   appears in the widget.

Nothing is written into an agent's configuration until you press an install button. Connect the
other agent later in **Settings… → Tooling → Open Tooling…**. For Claude, **Connect Status Line** adds the
context size and account usage to the widget; your own status-line command keeps running.

<details>
<summary>The connection guide</summary>

<img src="docs/images/setup-connect.png" alt="The connection guide: the install button, what the hooks send, and the optional Claude status line" width="480">

</details>

## Where a click takes you

| Where the agent runs | A click on its row |
|---|---|
| Ghostty | Brings forward the exact tab. macOS asks once for Automation permission |
| A JetBrains IDE terminal, with the [plugin](#jetbrains-ide-plugin) | Brings forward the exact terminal tab |
| Claude desktop app; Codex in the ChatGPT desktop app | Opens that session in the app |
| A Claude Code session sent to the background (`/bg`) | Opens `claude attach` for it in a new Ghostty tab |
| Any other terminal or IDE | Brings the app forward with all its windows |

If a terminal was closed and its agent kept running, the click asks whether to end that agent.

## Without the widget

<img src="docs/images/menu.png" alt="The menu: a summary line, seven sessions with their state marks, Show Widget, Settings and Quit" width="282">

The menu lists your sessions in the widget's order, and choosing one is the same as clicking its
row. **Show Widget** or **Hide Widget** stays at the same place. By default it lists the sessions
that need you and the finished ones; the picture lists all four groups, as chosen in
**Settings… → Menu Bar**.

<img src="docs/images/clip-menu.avif" alt="The menu shows who needs you; choosing that session opens its terminal tab, and after the answer the menu shows it done" width="640">

<img src="docs/images/clip-icon.avif" alt="The menu bar sphere turns orange when a session starts waiting for you" width="640">

| Sphere (default) | Counts |
|---|---|
| <img src="docs/images/menubar-sphere.png" alt="Sphere icon with a patch of colour for each state" width="38"> | <img src="docs/images/menubar-counts.png" alt="Counts icon: 2 need you, 3 working, 1 done, 1 idle" width="67"> |

<img src="docs/images/clip-counts.avif" alt="Choosing Counts as the icon style in Settings changes the menu bar icon at once" width="800">

On a full-screen display, where the menu bar is hidden, a small dot in a top corner shows while a
session needs you or works.

## Make it yours

Every setting is in one window: **Settings…** in the menu, or `⌘,` while the menu is open.

**Themes.** A theme holds every colour and animation: the panel, each lamp, the menu bar icon and
the menu's marks, for light and dark mode. On macOS 26 the panel can be Liquid Glass. Edit a
theme with live examples, export it, or import one somebody shared.

| Default, dark mode | Default, light mode | A theme of your own |
|---|---|---|
| <img src="docs/images/look-dark.png" alt="Default theme in dark mode: blue panel" width="250"> | <img src="docs/images/look-light.png" alt="Default theme in light mode: light grey panel" width="250"> | <img src="docs/images/look-own.png" alt="A custom theme: dark navy panel and pastel lamps" width="250"> |

<img src="docs/images/clip-light.avif" alt="Choosing Light in Appearance recolours the widget at once" width="800">

**Rows.** Choose and reorder what a row shows: elapsed time, lamp, agent, name, project, branch,
model, running work, context size, where it runs.

<img src="docs/images/row-minimal.png" alt="Rows with only a lamp and a name" width="260">
<img src="docs/images/row-full.png" alt="Rows with every part: time, lamp, agent, name, project, branch, model, running work and context" width="620">

<img src="docs/images/clip-branch.avif" alt="Ticking Branch among the row parts adds the branch, main, to every row" width="800">

**Order.** Arrival (rows never move by themselves), by state, by blocks you arrange, or by recent
activity.

| Arrival | By state | By blocks |
|---|---|---|
| <img src="docs/images/order-arrival.png" alt="Sessions in the order they arrived" width="250"> | <img src="docs/images/order-state.png" alt="Sessions grouped by state, the ones that need you first" width="250"> | <img src="docs/images/order-blocks.png" alt="Active sessions first, then the quiet one, then the failed one" width="250"> |

<img src="docs/images/clip-order.avif" alt="Choosing By state puts the session that needs you first" width="800">

**Size** goes from 50% to 200%; here at 75% and 150%.

<img src="docs/images/size-75.png" alt="The widget at 75%" width="270">
<img src="docs/images/size-150.png" alt="The widget at 150%" width="450">

<details>
<summary>The settings pages</summary>

<img src="docs/images/settings-rows.png" alt="Rows page: a preview and the list of parts to tick and drag" width="570">
<img src="docs/images/settings-order.png" alt="Order page: a playing preview, the four orders and the blocks" width="570">
<img src="docs/images/settings-menu-bar.png" alt="Menu Bar page: icon style, the states it shows, what the menu lists, the full-screen dot" width="570">
<img src="docs/images/settings-theme.png" alt="Theme editor: panel colour, material, opacity, and colour, motion and speed of each lamp" width="570">

</details>

## JetBrains IDE plugin

Optional. It takes a click to the **exact terminal tab** in a JetBrains IDE (platform 2025.1 or
newer, classic and reworked terminals), and needs the Agent Watch app.

1. Download `agent-watch-ide-<version>.zip` from the same
   [Releases](https://github.com/glockbender/agentwatcher/releases) page.
2. In the IDE: **Settings → Plugins → ⚙ → Install Plugin from Disk**, select the ZIP, restart if asked.
3. In Agent Watch: **Settings… → Tooling → Open Tooling…**, press **Check** beside the IDE.

## Privacy

- Session state stays on your Mac. Hooks send events over a local socket only your user can open.
  When Agent Watch is not running they fail open, and the agent goes on as usual.
- For names, branch and context size the app reads the agent's own files on disk, such as the
  Claude transcript and the Codex thread index. **Settings… → General** sets how often.
- It writes `~/.claude/skills/agent-watch/` for Claude, its own entries in `~/.codex/hooks.json`
  for Codex, the `statusLine` key in `~/.claude/settings.json` only if you connect the status
  line, and its state in `~/Library/Application Support/AgentWatch/`.
- It goes online only to check GitHub for updates and to download a release you chose to install.

Details: [installing into the agents](docs/agent-install.md), [architecture](docs/architecture.md).

## Uninstall

1. **Settings… → Tooling → Open Tooling…**: press **Remove** for each agent and **Disconnect** for
   the status line. This takes out everything the app wrote into the agents.
2. Quit Agent Watch and move it to the Trash. To forget settings and sessions too, move
   `~/Library/Application Support/AgentWatch/` to the Trash.
3. If you installed the IDE plugin, uninstall it in the IDE: **Settings → Plugins**.

## If something looks wrong

A session does not appear, has no name, or a lamp looks stuck: see [Troubleshooting](TROUBLESHOOTING.md).

## Build from source

Requires Xcode 16 or newer and [Task](https://taskfile.dev/). Liquid Glass needs Xcode 26 and its
macOS 26 SDK; with an older Xcode the widget is frosted instead.

```sh
task verify   # formatting, tests, debug and release builds, app bundle
task run      # run the app
```

Development notes are in [AGENTS.md](AGENTS.md); project documents, in Russian, are in
[docs](docs/).

MIT — see [LICENSE](LICENSE).
