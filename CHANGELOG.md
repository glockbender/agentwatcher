# Changelog

What changed in each release of Agent Watch, for the person updating it. An installed copy shows
the versions newer than itself in its update window.

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
