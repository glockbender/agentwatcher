# Agent Watch development guide

## Architecture invariants

- `AgentWatchApp` owns macOS lifecycle and presentation only.
- `AgentWatchCore` holds deterministic domain state and must not import AppKit. It reads the file
  system only where the file system is the subject — finding an agent's file among file names.
- Lifecycle facts are deterministic; LLM output must never become the source of session state.
- Monitoring failures are fail-open and must not block an agent.
- Avoid polling while there are no active sessions.
- `AgentWatchLookup` asks the machine and answers; `AgentWatchSender` builds a request and
  sends it. Neither does the other's job — that is what the two targets are for.

## Required checks

Two gates, both installed by `task setup`:

- **commit** — `task verify`: format, tests, debug and release builds, app bundle. Does not cover
  `ide-plugin/`.
- **push** — `task verify-all`: the above plus the IDE plugin (`task plugin-check`: build and
  tests, without staging — the staged file may be a signed release), the network probe that
  downloads a published release (`task probe-update`), and the end-to-end update
  (`task e2e-update`). About a minute. The plugin is skipped where no JetBrains IDE is installed,
  and the end-to-end part is skipped under `CI` or with `SKIP_E2E=1` — it opens dialogs on screen
  and answers them. The hook runs the gate only when a branch is pushed; a tag or a deletion goes
  through without it.

The IDE plugin needs nothing installed for itself: its Gradle wrapper fetches Gradle and its own
JDK. It compiles against a JetBrains IDE, taken from this machine when one is here (GoLand or
IntelliJ IDEA, 2026.1 or newer — an older one is refused with the reason) and downloaded when none
is — `task plugin-download` forces the downloaded path.

Add or update tests for every domain-state transition. Keep UI thin enough that important behaviour
can be tested in `AgentWatchCoreTests` without launching an application.

## Local development

- **A local bundle loses macOS permissions on every rebuild unless it is signed with a
  certificate.** `scripts/build-app.sh` uses one called `Agent Watch Developer` when the keychain
  holds it; the reasoning is in the script's own comment. To create it: Keychain Access →
  Certificate Assistant → Create a Certificate…, Self Signed Root, Code Signing. It does not need
  to be trusted, and `security find-identity -v` will not list it for that reason.
- **`task verify` rebuilds `dist/` from scratch**, so hooks installed from `dist/AgentWatch.app`
  point at a bundle that will be replaced. Copy it to `/Applications` and install from the copy.
- **One Agent Watch runs at a time.** Quit an installed copy before running a build:
  `osascript -e 'quit app "AgentWatch"'`.
- **The shared Xcode scheme is committed on purpose.** Xcode builds only the products a scheme
  names, and the generated one left out `AgentWatchSend` — so hooks installed from Xcode pointed at
  a file that did not exist.
- When Xcode is installed but `xcode-select -p` still points at the Command Line Tools:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer task verify`.
- **A click on the widget is checked with a real mouse event, not by calling `mouseDown`.**
  The widget moves when its background is dragged, and by default AppKit lets one press both
  reach a see-through view and start that drag — a click then also shifts the widget, which a
  test that calls `mouseDown` cannot notice. Run a debug copy with `AGENT_WATCH_SUPPORT_DIR`
  pointing at a scratch directory (see the end-to-end script for the launch), find its widget
  among the process's windows — both copies open at the same place, and the widget is not
  always window 1 — and post the click with `CGEventPost`: System Events' `click at` did not
  reach the row.
- **`task e2e-update` runs a throwaway copy beside yours and presses its dialogs itself.** It
  relies on two overrides a debug build has and a release build does not: the state directory
  from `AGENT_WATCH_SUPPORT_DIR` and the release address from `AGENT_WATCH_RELEASE_URL`. Your own
  Agent Watch has to be running — the copy it installs is a release build, and with nothing to
  find it would run against your real state — so the script refuses to start without it. The
  terminal needs Accessibility permission, which macOS asks for once.

## Documentation

Keep these current as part of the change, not after it.

- `docs/implementation-plan.md` — read before implementing; holds status, next milestones and
  deferred decisions.
- `docs/architecture.md` — product behaviour and architecture.
- `docs/agent-integration.md` — anything about attaching to Claude Code or Codex: hooks, install
  state, the status line, what each agent reports, and the measurements behind it.
- `docs/distribution.md` — how a release is built, signed and published.
- `README.md` — for somebody installing the app: keep it short, and put developer-only notes in
  this file instead.
