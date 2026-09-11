# Agent Watch development guide

## Scope

Agent Watch is a lightweight, AppKit-first macOS application for monitoring Claude Code and Codex sessions.

## Architecture invariants

- `AgentWatchApp` owns macOS lifecycle and presentation only.
- `AgentWatchCore` contains deterministic domain state and must not import AppKit.
- `AgentWatchCore` reads the file system only where the file system is the subject — finding an agent's file among file names. A rule that can be stated over the bytes somebody else read takes bytes, and is then tested without a disk.
- Hooks and external clients will communicate through a versioned local protocol.
- Lifecycle facts are deterministic; LLM output must never become the source of session state.
- Monitoring failures are fail-open and must not block an agent.
- Avoid polling while there are no active sessions.

## Required checks

Run `task verify` before committing. Use `task format` to apply the repository format.

`task verify` does not cover `ide-plugin/`: the JetBrains IDE plugin is Kotlin built by its own
Gradle wrapper against a locally installed IDE. Run `task plugin` when you change it. Install
nothing for it — the wrapper fetches Gradle and the build fetches its own JDK.

Add or update tests for every domain-state transition. Keep UI code thin enough that important behavior can be tested in `AgentWatchCoreTests` without launching an application.

## Local development

Five things the code does not say:

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

Read `docs/implementation-plan.md` before implementation and the relevant parts of `docs/architecture.md` when a change affects product behavior or architecture. Anything that touches how Agent Watch attaches to Claude Code or Codex — hooks, install state, the status line, what each agent reports — belongs to `docs/agent-integration.md`, which holds the differences between the two and the measurements behind them. Update those documents when requirements, architecture, delivery status, or deferred decisions change. `README.md` is for somebody installing the app, not for working on it: keep it short, and put what only a developer needs here instead. How a release is built and signed belongs to `docs/distribution.md`.
