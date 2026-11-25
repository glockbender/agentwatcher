# Shared Agent Memory connection probe

This archived study records a native HTTP connection test using real Claude Code and
Codex clients against one disposable Agent Memory bank. It excludes desktop windows,
Keychain access, project-to-bank routing, installation and update migrations. The ongoing
design is in [the managed memory plan](../proposals/managed-memory.md).

> Archived on 2026-11-21. This is a snapshot of the tested versions, not a promise about
> later releases. Repeat the executable probe for a new measurement.

## Result and tested versions

Claude Code 2.1.326 and Codex CLI 0.163.0 shared one Agent Memory HTTP server on macOS
27.2, build 26B123. Both clients read the other client's records. After a server restart,
the first read from each existing client process succeeded. Both also recovered after an
explicit call while the server was unavailable. No client restart, manual MCP reconnect
or configuration reload was needed in this test.

The connection checks passed, but server shutdown did not: Agent Memory exited with
status 1 after its 10-second HTTP shutdown deadline while clients remained connected.
Without clients, and after clients disconnected, it exited with status 0 immediately.

| Program | Exact source |
|---|---|
| Claude Code | Installed CLI 2.1.326 |
| Codex | Installed CLI 0.163.0, exercised through its `app-server` protocol |
| Agent Memory | Clean checkout `d3405d2990d6a8cff5283fccc33b63dad1b683e5`, built locally without source changes |
| Operating system | macOS 27.2, build 26B123, Apple Silicon |

Tested Agent Memory executable SHA-256:
`157a903f6a64a362a9c8bf8f9a636b628d3d7bf2bff459d7b10294a52dd2cc7b`.

## Isolation and what was real

The [probe](../../scripts/probe-memory-connection.py) creates fresh client homes, profiles,
temporary directories, an explicit Agent Memory configuration and bank files beneath a
new output directory. Child environments are constructed from an allowlist instead of
inheriting the calling session. Agent Memory receives `--config` so its normal configuration
search does not read Homebrew or user configuration. Claude uses a strict explicit MCP
configuration. Codex uses a fresh `CODEX_HOME`. Every HTTP address is on the local loopback
interface; client profiles use a public fixture authentication string, not a real credential.

Claude Code receives deterministic local Anthropic-format model responses that request
the real MCP tools. Codex invokes tools through its installed app-server's native
`mcpServer/tool/call` operation, without a model request. Neither path replaces the client's
MCP implementation. The memory server, SQLite storage, calls, failures and reconnection
are real. Only Claude's model decisions are scripted.

The bank uses text-only memory with document indexing, automatic session summaries,
background compilation and maintenance jobs disabled. Its embedding-provider address
points at the local fixture, not an installed model service. The probe performs no login,
Keychain operation, client setup command, system-service registration or package update.
It neither reads nor changes working memory databases or agent settings.

## Scenarios

All 14 connection checks passed on Claude Code 2.1.326 and Codex CLI 0.163.0:

| Scenario | Observed result |
|---|---|
| Claude writes a synthetic fact | Successful write |
| Codex reads Claude's fact | Returned the complete stored content and its record ID |
| Codex writes another fact | Successful write |
| Claude reads Codex's fact | Returned the complete stored content and its record ID |
| Stop and start the server at the same address | First read from each original client succeeded |
| Call both clients with the server stopped | Both returned a tool/connection error |
| Start the same bank again | First read from each original client succeeded |
| Codex writes after recovery | Successful new write |
| Claude reads the new fact | Returned the complete new stored content |
| Inspect only the disposable bank using a read-only SQLite connection | Exactly the three expected facts, without duplicates |
| Check client processes after both restarts | Both original processes remained alive |

The test intentionally repeats reads, not uncertain writes. It does not establish safe
automatic write retries when a response is lost after a commit.

## Shutdown finding

On Agent Memory `d3405d2`, Claude Code 2.1.326 and Codex CLI 0.163.0 kept HTTP event
streams connected while the test sent `SIGTERM` to the server. The two shutdown attempts
with live clients took 10.004 and 10.006 seconds, exited with status 1 and logged:

```text
error: http server error: http server shutdown failed: context deadline exceeded
```

The control shutdown before client startup took 0.008 seconds with status 0. After closing
the clients, final server shutdown took 0.002 seconds with status 0. No forced kill was
needed in the completed run.

Code inspection explains this result: `internal/server/server.go` waits up to ten seconds
in `http.Server.Shutdown`, while `serveMCPSSE` in `internal/server/console.go` keeps the
GET event stream open until its request context ends. There is no server-shutdown signal
in that stream loop. This is the likely cause, supported by the live-client/control
comparison; it has not been fixed by this probe. A subsequent complete run reproduced
the first ten-second failure but completed its second stop normally in 0.003 seconds.
The failure therefore depends on connection state; it does not occur on every stop merely
because the client processes are still alive.

Before managed updates, Agent Memory needs a regression test with a connected event
stream and graceful shutdown, then a shutdown signal that releases these streams without
discarding in-flight writes. Rerun this client probe after that change. Do not interpret
successful reconnect as proof that the current shutdown path is ready for updates.

## Reproduction and evidence

From the Agent Watch repository, with the sibling Agent Memory checkout available:

```sh
probe_dir=$(mktemp -d /private/tmp/aw-memory.XXXXXX)
env GOCACHE=/private/tmp/codex-go-cache go -C ../agent-memory-mcp build \
  -o "$probe_dir/agent-memory-mcp" ./cmd/agent-memory-mcp
python3 scripts/probe-memory-connection.py \
  --memory-binary "$probe_dir/agent-memory-mcp" \
  --output "$probe_dir/results"
```

`--output` must name a new directory. All fixture data is retained there for inspection;
the probe does not delete it. `--claude` and `--codex` can select exact installed binaries.
The probe requires permission to bind local ports and has bounded client/server waits.

Exit status 0 means connection checks and shutdown passed; 1 means a connection/probe
failure; 2 means connection checks passed but graceful server shutdown failed. The measured
run returned 2. `report.json` separates `transport_passed` from `graceful_shutdown_passed`
and records each check, client IDs, server IDs, versions, executable hash and stop timings.
`*.events.jsonl` and stderr files hold the isolated client/server evidence.

Repeated completed runs reproduced shared access and first-call recovery. The reference strict
run also checked full stored content, exact bank contents, unchanged client processes and
shutdown controls. All its test processes exited during cleanup.

## Remaining first-milestone checks

This result covers installed Claude Code CLI and Codex app-server behavior. It does not
establish behavior of desktop windows or their configuration reload controls. Native
project scoping across two banks/worktrees, Keychain helpers, login/service registration,
signed distribution and a lost write response still need separate isolated checks.
No existing profile or bank should be adopted based on this result alone.
