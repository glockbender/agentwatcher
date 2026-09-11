# Agent Watch development guide

## Architecture invariants

- `AgentWatchApp` owns macOS lifecycle and presentation only.
- `AgentWatchCore` holds deterministic domain state and must not import AppKit. It reads the file
  system only where the file system is the subject — finding an agent's file among file names.
- Lifecycle facts are deterministic; LLM output must never become the source of session state.
- Monitoring failures are fail-open and must not block an agent.
- Avoid polling while there are no active sessions.

## Required checks

Run `task verify` before committing; `task setup` puts it in a pre-commit hook. It does not cover
`ide-plugin/` — run `task plugin` when you change the IDE plugin, and install nothing for it: its
Gradle wrapper fetches Gradle and its own JDK.

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
