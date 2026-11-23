# Searching anonymized conversation excerpts

This archived study records retrieval of selected real conversation excerpts from a
disposable Agent Memory bank through Claude Code and Codex, before and after a server
restart. It excludes full transcript ingestion, automatic anonymization, semantic search,
desktop windows and Keychain access. Connection isolation and the shutdown finding are
covered by the [earlier connection study](managed-memory-connection.md).

> Archived on 2026-11-21. These results apply to the recorded versions and small fixture.
> Repeat the probe for later versions or a different collection.

## Source and privacy

The [fixture](../../scripts/fixtures/memory-conversation.json) contains five manually
selected excerpts from the current user-assistant design conversation. It preserves the
original Russian wording and generic speaker roles. Personal identities, machine paths,
repository addresses and session identifiers were omitted; product names were retained.
No transcript files, other chats, working profiles or working memory databases were read
to prepare this fixture. This selection is basic anonymization, not an automatic redactor
for arbitrary history exports.

The excerpts cover the shared server, independent service lifetime, restoring data after
an update, connecting an existing service and the source of session lifecycle facts.
Their source status is a design discussion. They do not establish shipped product behavior
and were stored as episodic memories, without automatic promotion or compilation.

Fixture SHA-256:
`514bff0991979e290ac40353828c031784760410ddaf5c80839fe5f7386da83f`.

## Measurement

The run used Claude Code 2.1.326, Codex CLI 0.163.0 through its app-server, macOS 27.2 and
the unchanged Agent Memory source at `d3405d2990d6a8cff5283fccc33b63dad1b683e5`.
Both clients used native HTTP MCP connections to one fresh server and bank. Claude model
responses were scripted locally; all memory calls, retrieval and storage were real.
No hosted model or embedding service was used. This was text-only retrieval.

The clients alternated writing the five excerpts. Each client then asked six Russian
questions before and after the server restart: 24 retrieval checks in total. Each check
requested at most three results and looked for the expected server-assigned record ID.
The ID was not included in the search query, so echoing a question could not pass the check.

| Question | Before restart, Claude / Codex rank | After restart, Claude / Codex rank |
|---|---|---|
| зачем нужен общий сервер для агентов | 1 / 1 | 1 / 1 |
| почему закрытие Watcher не отключает память | 1 / 1 | 1 / 1 |
| почему нельзя автоматически восстановить старую копию базы после обновления | 2 / 1 | 2 / 2 |
| как подключить уже работающий внешний сервис | 1 / 1 | 1 / 1 |
| может ли память определять состояние сессий | 1 / 1 | 1 / 1 |
| как отменить обновление после сохранения новых знаний | 1 / 1 | 1 / 1 |

The expected excerpt appeared among the first three results in all 24 checks, and first
in 21. This small collection demonstrates useful retrieval of the selected excerpts; it
does not measure quality on a large transcript archive. Reading memories changes access
statistics, so sequential queries can affect later ranking.

All 14 existing connection and recovery checks also passed. The original client processes
survived both server restarts, including an explicit failed call while the server was down.
The fresh bank contained exactly eight records: five excerpts and three synthetic control
facts. A read-only SQLite inspection after the run checked all records, not only the run's
context. Test processes stopped during cleanup without errors.

Graceful server shutdown still failed on a live-client stop, as in the earlier study.
The probe returned status 2, with `transport_passed=true`,
`corpus.retrieval_passed=true` and `graceful_shutdown_passed=false`.

## Reproduction

After building Agent Memory as described in the earlier study, run from Agent Watch:

```sh
python3 scripts/probe-memory-connection.py \
  --memory-binary /path/to/test-build/agent-memory-mcp \
  --corpus scripts/fixtures/memory-conversation.json \
  --output /private/tmp/aw-conversation-new-run
```

The output directory must not exist. All profiles, bank files and logs are created there.
The corpus option accepts an explicitly selected, already-anonymized fixture; it does not
export or anonymize local client history. Omitting the option keeps the synthetic baseline.

The JSON report separates connection checks, corpus retrieval checks and graceful shutdown.
Status 3 means connection checks completed but an expected excerpt was absent from the
first three results; the other statuses retain their meaning from the earlier study.

The final explicit rank bound and full-bank query were also revalidated against the
retained run report and read-only bank after the clients exited. No production Agent Memory
code or working client configuration changed.
