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

## Documentation

Read `docs/implementation-plan.md` before implementation and the relevant parts of `docs/architecture.md` when a change affects product behavior or architecture. Anything that touches how Agent Watch attaches to Claude Code or Codex — hooks, install state, the status line, what each agent reports — belongs to `docs/agent-integration.md`, which holds the differences between the two and the measurements behind them. Update those documents when requirements, architecture, delivery status, or deferred decisions change. Update `README.md` when commands, supported toolchain, project structure, or setup changes.
