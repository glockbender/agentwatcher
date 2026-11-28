# Changelog

What changed in each release of Agent Watch, for the person updating it. An installed copy shows
the versions newer than itself in its update window.

## [0.6.0] - 2026-11-28

### Added

- **Projects & Recent** groups Claude Code and Codex chats by repository. Search by branch or chat name and reopen a conversation.
- The Notification Center widget opens **Projects & Recent**. The medium widget also opens the waiting list and Settings.
- **Settings → Working Copies** shows disk use by Git working copy and lets you move eligible build caches to the Trash.
- **Usage profiles** shows recorded account limits and available reset times for the default Claude profile and configured Codex profiles.
- **Settings → Resources** shows memory and CPU use for agents and the Mac. Add **Memory & CPU** to a row for session figures.

### Changed

- After updating, if you connected the Claude status-line relay, restore your original command before deleting the relay or Agent Watch support folder.
  [Restore the status-line command](https://github.com/glockbender/agentwatcher/blob/v0.6.0/TROUBLESHOOTING.md#claude-still-runs-the-agent-watch-status-line-relay).
- **Settings → Git Protection** shows hook status by profile. One switch controls all profiles. Turning protection off requires confirmation and keeps the installed hooks.
- **Force Push** and **Delete Remote Branch** have separate rules. Preview the check for a branch or set a stricter rule for one repository.
- **Settings → Menu Bar** can show Claude and Codex account limits and memory and CPU use for agents and the Mac.

### Removed

- Agent Watch’s Claude status-line integration. Claude Code provides the account limits.

### Fixed

- The settings toolbar stays clear of scrolling text.

## [0.5.0] - 2026-11-22

### Added

- Git protection: **Settings → Git Protection** installs a hook in each Claude and Codex profile
  that asks you before a risky push, such as deleting a protected branch.
- The waiting beacon lists the chats waiting for your reply; click it and choose one to open that
  chat in desktop Claude or Codex.
- The waiting beacon can also show on windowed desktops: choose **All modes** in
  **Settings → Waiting Beacon**.

### Changed

- After updating, if you use Mothership Git protection, install the hook for each profile in
  **Settings → Git Protection** and trust it in Codex before updating Mothership.
- After updating, turn on the waiting beacon in **Settings → Waiting Beacon** if you want it: it
  replaces the full-screen dot and is off by default.
- The waiting beacon lights only while a chat waits for your reply, not while a session works.

## [0.4.0] - 2026-10-10

### Added

- The update window lists what changed in every version since yours, with a progress bar and a
  Cancel button.
- Tooling covers an agent's other folders (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`): Add Folder… installs
  the hooks there, and those sessions show up
  ([how it looks](https://github.com/glockbender/agentwatcher/blob/v0.4.0/README.md#more-than-one-agent-folder)).
- A click on a Codex session running in a terminal brings its tab forward, as it does for Claude.

### Changed

- Tooling is a page in Settings instead of a separate window; Connect Agent → in the empty widget
  opens it.
- Check for updates automatically replaces Check for updates on launch: it checks at launch and
  once a day.

### Fixed

- The full-screen dot shows over a full-screen terminal with tabs, such as Ghostty.
- Text the widget showed before no longer shows faintly through its background.

## [0.3.0] - 2026-10-08

### Added

- The app checks for a newer release at launch and installs it when you agree.
- A disk image for the first install: open it and drag Agent Watch to Applications.
- A guide from an empty widget to a connected agent.
- Themes: colours, the panel, the lamps and their movement, edited in Settings with live
  examples. Liquid Glass on macOS 26.
- A menu bar icon that shows whether anything waits for you.
- The menu lists every session, so you can switch to one without the widget.
- On a full-screen display, where the menu bar hides, a small dot in the top corner shows that a
  session needs you or is working.
- A key combination that shows and hides the widget from anywhere.
- Your choice of the widget's size, what a row shows, and the order of sessions in the widget and
  the menu.
- A Claude session shows the name you gave it; an MCP server's question shows on its row.
- A session whose terminal was closed is marked, and a click on it offers to end its agent.
- A click on a background session attaches it in a Ghostty tab.
- Headless runs (`claude -p`, the Agent SDK, `codex exec`) stay hidden unless Show headless runs
  is on.

### Changed

- Settings is one window with a page per subject, General first.
- A click on a row raises only the window with the session's tab, or opens a desktop client's own
  session.
- A Claude rate limit shows as paused, and a session that sends nothing counts as inactive.

### Fixed

- A resumed session no longer leaves a second row behind.
- The agent's own helper processes no longer show up as sessions.

## [0.1.0] - 2026-09-11

First public build.
