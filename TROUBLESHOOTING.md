# Troubleshooting

Situations that look like a bug in Agent Watch, why they happen, and what to do.

Each entry says which version it was checked on. Claude Code, Codex and macOS change without
notice, so on a newer version an entry may no longer be true.

## A Claude session shows `[still no name]`

**Why:** Claude Code names the session, not Agent Watch. After the first prompt of 10 or more
characters, Claude Code asks a model for a short title; your terminal tab shows the same title.
Shorter prompts, such as `show doc`, and slash commands do not count. Claude Code gives no titles
at all when `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is `1`, `true`, `yes` or `on`.

**What to do:** Send a prompt of 10 or more characters. Or name the session yourself: `/rename
<name>` in the session, or `claude --name <name>` when you start it. If a session has both names,
Agent Watch shows yours.

**Checked on:** Claude Code 2.1.284. Tested: the 10-character rule. Read in Claude Code's code but
not tested: slash commands and the environment variable.

## A session stays after you closed its Ghostty tab

**Why:** Ghostty sometimes removes a closed tab but keeps the terminal behind it, so the agent in it
keeps running. The tab is gone from every window, so a click has nothing to bring forward.

**What to do:** Click the row. The widget asks whether to end the broken session. Choose **End**
to end the agent and the shell of the closed tab. The row disappears after the agent exits. The
conversation is kept, and `claude --resume` continues it in a new tab.

**Checked on:** Ghostty 1.3.1, Claude Code 2.1.284. Seen once. Why Ghostty keeps the terminal is
not known.

## No session appears, and Tooling says "nothing has arrived yet"

**Why:** The connection is installed, but the agent has not loaded it. Claude Code loads plugins
when a session starts. Codex runs new hooks only after you trust them.

**What to do:** Claude Code: run `/reload-plugins`, or start a new session. Codex: accept its
prompt to trust the hooks. Then send a request.

**Checked on:** not recorded.

## No session appears, and Tooling says "Hooks missing" or "Points to a program that is gone"

**Why:** Agent Watch's entries in the agent's configuration are incomplete, or point to a program
that no longer exists.

**What to do:** Press **Repair** or **Point at this build** in Tooling.

**Checked on:** not recorded.

## Tooling says "The file exists but cannot be read"

**Why:** The file has an error, for example invalid JSON. Agent Watch does not change a file it
cannot read, so it cannot damage your settings.

**What to do:** Fix or move the file that Tooling names, then reopen Tooling.

**Checked on:** not recorded.

## A theme you added is not in the list

**Why:** Agent Watch could not read its file: it is not JSON, a value in it has the wrong type, or
a lamp in it lacks one of its four fields.
A file whose theme is called `Default` is listed as `Default (file)`, because the built-in theme
keeps that name.

**What to do:** **Settings → Appearance** names the file and what was wrong. Fix it in the Themes
folder (**Your Themes → Show Theme Folder**), or ask whoever shared the theme to export it again,
and use **Import…**. The folder is read again each time the settings window opens and each time it
shows Appearance, Edit Theme or Your Themes.

**Checked on:** macOS 15.3.1.

## The widget is frosted, though its material is Glass

**Why:** Liquid Glass comes with macOS 26. On an older macOS, or in a build made without the
macOS 26 SDK, the widget draws Glass and Clear glass as frosted.

**What to do:** Nothing is broken. On macOS 26 the same theme draws glass. The settings mark both
glass materials `(macOS 26)` where they cannot be drawn.

**Checked on:** macOS 15.3.1; what macOS 26 draws was read in the code, not seen.

## Arrow keys skip the sessions in the menu

**Why:** The sessions in the menu are one scrolling list, and macOS keeps every arrow key that can
move its own highlight. While there is a menu line above or below, the arrow goes there, and the
list never receives it. Agent Watch therefore marks the list as a line the arrows step over, so
they go straight from the line above it to the line below.

**What to do:** Choose a session with the pointer: hover over it and click, or scroll the list with
the trackpad. **Settings… → Menu Bar → Sessions before scrolling** sets how many sessions show
before the list scrolls.

**Checked on:** macOS 15.3.1.
