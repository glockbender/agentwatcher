# Troubleshooting

Things that look wrong in Agent Watch but have a cause you can act on — most often the agent
behaving in a way nobody would guess from the widget.

Each entry names the version it was checked on. Claude Code, Codex and macOS change without
notice, so an entry checked on an older version than yours may no longer hold.

## A running Claude session shows `[still no name]`

**Why:** Agent Watch does not choose the name. Claude Code names a session itself: after a prompt
of at least 10 characters, it asks a small model for a short title — the same title your terminal
tab shows. A shorter prompt such as `show doc`, or a slash command, does not count; the next longer
prompt does. Until then the tab keeps Claude Code's default title, and the row says
`[still no name] … ⓘ`. Hover the row to see this reason in its card. Claude Code names no session
at all when `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is set to `1`, `true`, `yes` or `on`.

**What to do:** Send a prompt of 10 or more characters, or name the session yourself: `/rename
<name>` in the session, or `claude --name <name>` when you start it. A name you give is shown
ahead of Claude's own title.

**Checked on:** Claude Code 2.1.284. The 10-character rule was reproduced in a session; the tab
title and the environment variable were read in Claude Code's code, not tried.

## No session appears, and Tooling says the connection is waiting for a signal

**Why:** Installing writes the agent's configuration. It does not prove the agent has loaded it:
Claude Code reads plugins when a session starts, and Codex asks you to trust new hooks first.

**What to do:** Claude Code: run `/reload-plugins` in an existing session, or start a new one.
Codex: accept its trust prompts for the hooks. Then send a request — the first signal changes the
state.

**Checked on:** not recorded.

## No session appears, and Tooling says the connection needs repair or cannot read a file

**Why:** A file Agent Watch wrote into was changed or moved, or a configuration file does not
parse. Agent Watch never writes over a file it cannot read, because it cannot know what the write
would destroy.

**What to do:** Use the repair action in Tooling. For a file it cannot read, Tooling offers no
action and names the file instead: fix or move that file, then reopen Tooling.

**Checked on:** not recorded.
