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

**What to do:** Click the row. It changes to "terminal closed". Click it again to end the agent and
the shell of the closed tab. The conversation is kept, and `claude --resume` continues it in a new
tab.

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
