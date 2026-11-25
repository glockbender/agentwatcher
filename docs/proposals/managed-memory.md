# Managed Agent Memory installation and updates

This proposal plans installation, service management and updates for Agent Memory MCP
through Agent Watch. It excludes a general extension marketplace, automatic model
installation, cross-project search and a full knowledge editor. Current session monitoring
is described in [architecture.md](../architecture.md); delivery progress belongs in the
[implementation plan](../implementation-plan.md).

**Status:** implementation plan, 2026-11-21. The isolated shared-connection probe is
complete; the other first-milestone checks and product implementation remain open.

## Accepted direction and proposed defaults

The accepted direction is one managed Agent Memory server per connected bank, shared by
Agent Watch, Claude Code and Codex. A bank is one persistent collection of knowledge and
its document index. Multiple banks initially mean separate server instances; supporting
many banks inside one server is not a prerequisite.

Agent Memory remains independently installable and usable. Agent Watch offers it in a
small built-in catalog, installs an upstream release and manages a user-level macOS
service. The service continues when Agent Watch exits. An explicit Stop persists across
application restarts and login; Start enables running at login again.

Proposed defaults for the first delivery:

- macOS on Apple Silicon; the existing app's supported OS range applies.
- Direct MCP over HTTP on the loopback interface, which only accepts local connections.
  Each instance has its own stable address, identity and credential.
- Native HTTP configuration for supported Claude Code and Codex profiles. A credential
  helper reads the macOS Keychain at connection time; no token goes into agent config.
- One writer: the server owns changes to bank data and background jobs. Hook commands
  and other commands for a managed bank send requests to it instead of opening storage.
- Basic memory works without downloading a model or contacting a hosted provider.
  Search limitations remain visible; semantic search is a later explicit configuration.
- Automatic compilation is off for managed banks, including imported plugin settings.
  Enabling it later requires selecting its provider, executable and account, and explaining
  what content leaves the computer. The existing headless Claude path is not a local model.
- Update checks follow a setting; applying an update is an explicit user action.
- Removing an installation stops its service and removes its owned connections, while
  keeping bank data and recoverable installation records by default.
- External services and existing package-manager installations are connect-only.
  Agent Watch does not take over their processes or update their executables.

These defaults refine the accepted direction. The client and storage facts listed below
must be established before promising a working installation or safe update.

## Existing code and missing behavior

Planning evidence is the Agent Watch working tree based on `57c71d4` and the local
Agent Memory checkout at `d3405d2`. Existing unrelated working-tree changes are outside
this plan. These are source inspections, not results from testing installed clients.

| Repository | Reusable code | Missing behavior |
|---|---|---|
| Agent Watch | `ToolingCoordinator`, `ToolingInstaller`, agent profiles and settings | Installed product inventory, service ownership, MCP client, managed bank UI and update transactions |
| Agent Watch | `AppUpdater` uses Sparkle for the application bundle | Separate updates for external server releases; Sparkle does not define bank backup or migration |
| Agent Memory | HTTP server, `/mcp`, `/health`, graceful HTTP shutdown and client session IDs | Stable bank identity, management operations, per-client roles and durable maintenance state |
| Agent Memory | `setup_agents.go`, `config_snippets.go`, Claude plugin and hook commands | Native HTTP registration; current setup forces a new stdio server, and hooks/CLI can write directly |
| Agent Memory | Existing JSON bank views, release archives and macOS service example | Structured search results, signed managed-install metadata and a supported update/storage contract |

Source areas in Agent Memory are `cmd/agent-memory-mcp`, `internal/server`,
`internal/config`, `internal/memory`, `internal/vectorstore`, `plugin`,
`deploy/macos` and `.goreleaser.yaml`.

Both clients document native HTTP connections and header helpers:
[Claude Code MCP](https://code.claude.com/docs/en/mcp) and
[Codex MCP](https://developers.openai.com/codex/mcp/).
Actual desktop behavior, Keychain access and reconnect behavior need the first milestone.
For macOS service registration, choose the supported mechanism for independently
installed user executables during that milestone; the existing plist is a starting point,
not proof of distribution compatibility.

## Ownership and storage

Agent Memory owns the storage format, server behavior, background compilation, duplicate
handling and supported backup/migration operations. Its repository publishes a versioned
Agent Watch integration package beside its existing distribution formats. The package
describes supported management operations, capabilities, release signatures and compatible
versions. The first catalog entry uses a dedicated adapter; no arbitrary extension scripts
or dynamically loaded code execute inside Agent Watch.

Agent Watch owns installation records, downloads, verified extraction, service registration,
user-visible decisions, agent connection edits and update recovery. Proposed new module
`AgentWatchMemory` holds this external-service work. Its deterministic state types stay
independent of AppKit and are tested through injected dependencies. `AgentWatchApp` owns
presentation and composition. Do not put HTTP, installation or service control into
`AgentWatchCore`, `AgentWatchLookup` or `AgentWatchSender`.

An installed launch helper shares the management journal reader with `AgentWatchMemory`
and lives outside the application bundle. It checks desired state, credentials, crash
budget and the committed executable/data selection before opening storage, then replaces
itself with the selected server process. There is no additional long-running supervisor.
If an interrupted transaction leaves the selection unresolved, this helper remains stopped
with a repair reason; the first version does not complete migrations without Agent Watch.

Keep signed executable versions, non-secret instance settings, bank data and backups in
separate locations. Bank data belongs in Agent Memory's user data area, not in the app
bundle, plugin download cache or repository. Use an immutable bank ID rather than a
project folder name; project moves and Git worktrees must not create an empty replacement
bank. Persist an explicit repository-to-bank binding shared by connection setup, hooks
and the window. Worktrees inherit their repository's selected bank; moved repositories
reattach by explicit confirmation, never by folder-name matching. Native client scoping
must expose only the selected bank for that project. Do not install every bank as a global
connection. Persist each instance's chosen executable and address. Updating one instance must
not silently change another instance using the same installed release.

Never treat an occupied port, a process name or an arbitrary successful `/health` reply
as proof of ownership. Authenticate and compare instance ID, bank ID and version before
control operations. If the stored address belongs to something else, report a conflict
without stopping it or silently selecting a different address.

Local user-level service control uses a separately protected management channel, proposed
as a user-only Unix socket. Agent MCP credentials cannot invoke service maintenance or
restore. Agent Watch gets a read-only browsing role that does not generate automatic
session summaries; coding clients retain memory access. Roles are enforced by the server,
not by tool hints or a caller's self-reported name. Logs and diagnostics omit credentials
and transcript content. This plan specifies credential handling but does not access any
existing credentials.

The installer provisions separate browser and writer credentials in a disposable-tested
Keychain flow. Define how the service loads its authentication material before accepting
connections; use verifier material where practical or a tested signed Keychain reader.
Test the helper's signing identity and stable path across updates. A locked Keychain,
missing item or denied access leaves the service unavailable with a repair action; it
never falls back to unauthenticated operation. Rotation and revocation update clients and
server coherently without putting credential values in settings, archives or logs.

## Delivery milestones

### 1 Prove the shared connection and recovery path

The [archived connection result](../research/managed-memory-connection.md) confirms shared
access and same-process first-call recovery on Claude Code 2.1.326 and Codex CLI 0.163.0.
It also records a graceful server shutdown failure that must be fixed before managed
updates. Desktop windows, credentials, project scoping and service/distribution checks
below remain unverified.

A [conversation-data probe](../research/managed-memory-conversation.md) additionally checks
five anonymized excerpts from the design discussion. All 24 text-only retrieval checks
find the expected record among the first three results through both clients before and
after restart, on the versions recorded in that study. This is a small fixture, not a
semantic-search or full-transcript ingestion result.

Build a disposable test bank and a local development server. From each installed desktop
client and Agent Watch's test client, initialize MCP, write a uniquely identified test
record and read records created by the others. Also bind two different projects to two
different banks and include a worktree; verify native project scoping, required trust,
configuration precedence and agreement between MCP and hook routing. Test simultaneous
clients, HTTP sessions, restart with the same address, startup delay and an interrupted write response.
Record client versions next to the results when this is executed.

Verify native credential helpers using a disposable Keychain, with no credential in
config or diagnostics. Cover foreground setup, unattended service startup after login,
locked Keychain, removed credentials and helper/server replacement. Verify supported service registration and execution of downloaded
signed binaries on a clean macOS machine. Define the minimum supported client versions
from these results. If a client cannot support this path, resolve that compatibility
failure before implementing its setup flow; do not silently add a transport bridge.

Exit criterion: a reproducible fixture proves that both clients use one server and one
bank; reconnect and interrupted-request behavior are known. An unsupported client gets a
precise minimum-version or reconnect instruction, not a claim of seamless recovery.

### 2 Give Agent Memory a managed-service contract

Add managed instance configuration and persisted IDs; status reports distinguish process
startup, bank readiness, degraded retrieval and failure. Include executable version,
management protocol version, storage compatibility, active operations and last failure.

Add management operations for entering maintenance, waiting for active work, consistent
backup, preparing/validating a storage upgrade and reporting completion. Maintenance blocks
new mutation from MCP, hooks, compilation, indexing and background jobs. Graceful shutdown
has a bounded deadline. A timeout cancels the update; it does not force-kill a writer and
declare the snapshot safe. Confirm that shutdown-generated summaries are included before
the final snapshot. Maintenance state survives a manager crash.

All supported writers must respect a common bank lease. A managed server holds it while
running; direct CLI storage access refuses a leased managed bank or sends the operation
to that server. Hook capture, checkpoints, context injection and compilation gain a remote
mode. Existing standalone modes keep working for standalone banks.

Persist request IDs for capture and mutation operations that may be retried: the same
request has the same result after reconnect/restart. Commit each mutation and its retry
receipt in one transaction. Never automatically replay an
unidentified write after losing its response. Define expiry and the stored result of a
duplicate request. Do not equate a completed agent turn with a closed session.

For managed authoritative records and receipts, establish durable commit settings before
acknowledging a write. Current `internal/dbutil/sqlite.go` uses WAL with
`synchronous=NORMAL`, which can lose committed writes on power failure according to
[SQLite's documentation](https://www.sqlite.org/pragma.html#pragma_synchronous).
Use a verified durable setting for managed banks, including macOS flush behavior, without
silently changing the standalone preset. Test application crashes and machine interruption
separately. The contract assumes storage honors successful flush requests; document indexes
may be rebuilt, but acknowledged knowledge and retry receipts may not be discarded.

Remote capture uses a bounded private durable queue outside the active bank generation.
Create a compact redacted capture record with a stable event ID before acknowledging local
enqueue; do not keep a second raw transcript. A delivered event is removed only after the
server acknowledges it. Temporary failures and maintenance retain it for replay through
the server. A short-lived retry worker exits after bounded attempts. The managed server
owns queue drainage, triggered by queue changes, service startup and bounded retry delays
while pending events exist. It stops scheduling retries when the queue is empty. Lost
notifications or an exhausted hook worker must not require another hook or a server restart
to deliver pending events. Capture event IDs remain durable unique identities, including
tombstones for removed records; they do not expire with short-lived HTTP request receipts.
Define queue size/age limits and surface pending,
expired and rejected captures without blocking the agent. Never silently evict accepted
pending events. Explicit Stop disables new automatic capture; retained events stay visible
and resume only on Start. Context injection skips promptly when the server is unavailable.

Exit criterion: protocol tests prove role separation, writer exclusion, duplicate-request
behavior, bounded maintenance and consistent recovery after interruption. Include commit
followed by a lost response, exhausted hook retries and eventual delivery without restart;
replay after ordinary receipt expiry must not duplicate a captured event.

### 3 Publish an installable integration package

Publish a package from Agent Memory's release workflow containing the normal server
archive or its pinned reference, integration metadata and compatibility information.
Version the package contract separately from the Agent Memory executable; declare the
compatible Agent Watch versions and supported upgrade paths.

Authenticate metadata and archive hashes with a publisher key trusted by the catalog.
Use signed/notarized macOS executables or an independently verified supported distribution
path established in milestone 1; never bypass quarantine to make installation succeed.
Validate archive paths, symlinks, platform and expanded size before activation. Reject an
unsupported contract without executing it. Interrupted installation keeps the previous
installation usable and cleans up only its owned staged files.

Exit criterion: an empty macOS user account installs a pinned package without Homebrew,
Go, Docker or a preinstalled model; a modified archive is rejected.

### 4 Install and supervise from Agent Watch

Add `AgentWatchMemory` and a built-in Agent Memory catalog entry. Persist installation
ownership, instance ID, bank ID, desired running/stopped state, executable version, address
and credential references. Add a setup flow for a new bank or an external connection.

Install and execute from a stable user-owned location outside `AgentWatch.app`, `dist/`
and temporary folders. Register a user service with `launchd`, the macOS process launcher.
Start/Stop/Reconnect survive app restarts. Closing or upgrading Agent Watch leaves running
memory available. Explicit Stop disables automatic restart until Start.

Use restart throttling and a persistent startup-failure budget so repeated crashes settle
into a failed state even when Agent Watch is closed. The startup guard belongs to the
installed launch helper described above; it is not another long-running supervisor. Show the
last failure and an explicit Retry. Observe service exits and check readiness on operations
or while its screen is visible; do not poll disconnected banks in the background.

Exit criterion: tested installation, repeated Start, intentional Stop, crash recovery,
repeated failure, logout/login, port conflict, app exit and app bundle replacement.

### 5 Connect agents and bring existing knowledge across

Extend Agent Memory's config generation for native HTTP, credential helpers and explicit
agent profile locations. Return structured plans/results so Agent Watch can preview and
apply owned edits without implementing a second config editor. Preserve unrelated entries,
approval rules and user edits; detect concurrent edits and conflicting server names.

Extend the Agent Memory Claude plugin with an external managed-instance mode: it must not
launch its own server or write a different bank. Managed-mode distribution supplies hooks
without the standalone plugin's stdio server registration. Verify that the actual plugin
mechanism supports this, or publish a hooks-only companion from the same sources. Route
capture and explicitly enabled compilation to the managed server. Replace only matching
owned setup hooks; do not disable unrelated agent
hooks. Add integration tests for plugin-only, setup-only, both installed and neither.
For Codex, preserve explicit memory tool writes; automatic transcript capture requires a
separately verified source and is not a prerequisite for this delivery.

Existing databases are imported into a managed copy after all source writers have stopped.
Retain the original bank and executable; never claim ownership of an existing Homebrew
service or reuse its active storage. Provide a cutover preview naming all old connections
and hooks that must stop writing. Abort if they cannot be identified and stopped; two live
banks presented as one would split knowledge. New managed writes do not merge back into
the retained original automatically.

Exit criterion: both agents and Watcher see the same record; accepted queued hook events
survive temporary outages and apply at most once; full queues and skipped captures are
visible; explicit Stop captures nothing new; rerunning setup changes nothing; worktrees
use the chosen bank; conflicting existing
installations remain intact and the cutover is explicit.

### 6 Add status and a small knowledge browser

In Agent Watch settings, add bank setup, status, version, last checked time, diagnostics,
Start/Stop/Retry, connection ownership and removal. Add search and record details in the
project window. Sources, timestamps and trust status remain visible. No unrestricted tool
console, automatic knowledge promotion or automatic transcript upload is needed.

In Agent Memory, extend search/read operations with structured results and output schemas,
retaining existing text output compatibility. Existing JSON project-bank views are reusable;
the current `core` profile does not expose every bank/steward operation, so add a dedicated
read-only browse role/profile rather than enabling all tools for the window.

Exit criterion: a person installs and connects a bank, finds a record created by either
agent and diagnoses a stopped or degraded server without reading source code. Memory
failures do not change session lifecycle facts or block monitoring.

### 7 Update with persistent recovery

Check for compatible signed releases according to a setting. Download and verify beside
the current release. Show affected bank, old/new versions, required disk space and any
storage change. Applying the update is explicit; do not infer safety from agent inactivity.

Serialize updates per bank and write a durable transaction journal before service/data
changes. Enter maintenance, drain requests and background work, and stop the service.
Verify the writer lease is free and no unsupported old writer remains. Prepare a consistent
snapshot of memory and document-index stores, including pending capture/compilation state.

Migrate a staged data copy with the new executable while the old data remains untouched.
Validate bank identity, storage integrity, pending work and a representative read. Keep the
candidate unavailable to ordinary clients until validation succeeds. Commit the executable
and data-generation selection recoverably, then reopen client admission. The stable address
and credentials remain; HTTP sessions may need a new MCP initialization.

Before admission, failure returns to the old executable and untouched old data. After the
candidate accepts writes, automatic restoration of an old snapshot is forbidden because
it could lose acknowledged knowledge. Preserve both generations, stop further unsafe
changes and offer forward repair or an explicit data-loss-aware restore. Downloads, copies
and migrations handle cancellation or insufficient disk without damaging the live bank.

The journal and committed selection must reach durable storage in the defined order before
client admission. On Agent Watch crash, server crash or machine reboot, the installed launch
helper validates that selection before storage opens. An unresolved transaction stays
stopped for Agent Watch's recovery flow, even when Watcher is absent. Missing packages and cleanup must
not erase the only usable generation. A bank already stopped stays stopped after update.

Exit criterion: fault injection at every boundary proves acknowledged records survive,
the right executable/data pair starts, concurrent updates cannot race and each client can
reconnect or receives its tested recovery instruction. Exercise two independent banks so
updating one does not restart or migrate the other.

## Checks and implementation order

Milestone 1 precedes the management contract. Milestones 2 and 3 precede managed installation.
Agent registration follows a working service and remote hook path. Ship the first public
managed-bank delivery only after milestone 7; publishing installation without a supported
update path would leave user data dependent on an unfinished mechanism.

For Agent Memory changes, run plain `go test` for changed packages during iteration and
the repository's `make test` and `make vet` gates before delivery. Run `-race` once in the
final pre-commit check. Include process-level tests with temporary banks, concurrent clients,
real shutdown signals, write-response loss, role enforcement and interrupted upgrades.

For Agent Watch, test deterministic service/update transitions through the module interface,
then run the project gates `task verify` before commit and `task verify-all` before an
authorized push. Add a bounded `task e2e-memory` fixture on a disposable macOS machine for
clean install, real desktop clients, Keychain prompts, service recovery and update failure.
It is a proposed task, not an existing command. The fixture uses synthetic records and
isolated agent profiles; it never changes the user's real memory or credentials.

Before release, document managed behavior in the owning documents: service/data/update
rules in Agent Memory; installation, settings and distribution in Agent Watch. Clarify the
existing no-daemon statement as no separate Agent Watch session-state daemon: the explicitly
installed memory product owns its service. Record the shared-server/independent-lifetime
trade-off in an ADR at implementation time. Keep the README about shipped behavior and
leave CHANGELOG generation to release time.

## Next implementation task

Continue milestone 1 using the existing connection fixture. Fix and regression-test Agent
Memory's graceful HTTP shutdown with connected event streams, then rerun both real clients.
Complete isolated credential, project scoping, desktop and service/distribution checks before
fixing the public management contract or implementing an installer. The connection result
alone does not complete milestone 1.
