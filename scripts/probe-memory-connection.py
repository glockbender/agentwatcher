#!/usr/bin/env python3
"""Probe real Claude Code and Codex clients against an isolated Agent Memory HTTP bank.

Only model responses are scripted. Both clients perform their own native MCP calls.
All client profiles, records and logs are new files under the required output directory.
No login, package installation, real credential or existing client profile is needed.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid


FIXTURE_AUTH = "fixture-only-not-a-real-credential"
MEMORY_ID = re.compile(r"\bID:\s*`?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\b")


class ConversationCorpus:
    def __init__(self, path):
        self.data = json.loads(path.read_text())
        self.digest = hashlib.sha256(path.read_bytes()).hexdigest()
        self.entries = self.data["entries"]
        self.queries = self.data["queries"]
        ids = [entry["id"] for entry in self.entries]
        if not ids or len(ids) != len(set(ids)):
            raise ValueError("Corpus entries need unique IDs")
        if any(query["expected_entry"] not in ids for query in self.queries):
            raise ValueError("Corpus query refers to an unknown entry")
        self.stored_ids = {}
        self.checks = []

    def populate(self, clients, context):
        for index, entry in enumerate(self.entries):
            client = clients[index % len(clients)]
            result = client.call("store_memory", {"title": entry["title"], "content": entry["content"],
                                                 "type": "episodic", "context": context})
            ids = MEMORY_ID.findall(json.dumps(result, ensure_ascii=False))
            if result.get("isError") or len(ids) != 1:
                raise RuntimeError("Failed to store conversation entry " + entry["id"])
            self.stored_ids[entry["id"]] = ids[0]

    def evaluate(self, clients, context, phase):
        for query in self.queries:
            expected = self.stored_ids[query["expected_entry"]]
            for name, client in clients:
                result = client.call("recall_memory", {"query": query["query"], "context": context, "limit": 3})
                ids = MEMORY_ID.findall(json.dumps(result, ensure_ascii=False))
                rank = ids.index(expected) + 1 if expected in ids else None
                passed = not result.get("isError") and rank is not None and rank <= 3
                self.checks.append({"phase": phase, "client": name, "query_id": query["id"],
                                    "query": query["query"], "expected_entry": query["expected_entry"],
                                    "rank": rank, "passed": passed, "result": result})
                print(("PASS " if passed else "MISS ") + f"corpus {phase} {name} {query['id']} rank={rank}", flush=True)

    def summary(self):
        return {"sha256": self.digest, "entry_count": len(self.entries), "query_count": len(self.queries),
                "source": self.data.get("source"), "privacy": self.data.get("privacy"),
                "stored_ids": self.stored_ids, "checks": self.checks,
                "retrieval_passed": bool(self.checks) and all(item["passed"] for item in self.checks)}


def isolated_env(home):
    home.mkdir(parents=True)
    temp = home / "tmp"
    temp.mkdir()
    return {
        "HOME": str(home), "TMPDIR": str(temp),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/bash",
        "LANG": "en_US.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ALLOW_PROTOCOL": "file",
        "GIT_TERMINAL_PROMPT": "0",
    }


class JsonProcess:
    def __init__(self, command, cwd, env, log_prefix):
        self.messages = queue.Queue()
        self.stderr = log_prefix.with_suffix(".stderr").open("x")
        self.events = log_prefix.with_suffix(".events.jsonl").open("x")
        self.process = subprocess.Popen(command, cwd=cwd, env=env, text=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, bufsize=1)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            self.events.write(line)
            self.events.flush()
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                self.messages.put({"invalid_json": line[:200]})
        self.messages.put({"process_ended": True})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def wait(self, predicate, timeout=35):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if message.get("process_ended"):
                raise RuntimeError("Test client exited; inspect its isolated stderr")
            if predicate(message):
                return message
        raise TimeoutError(f"No expected client response within {timeout}s")

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        if self.reader.is_alive():
            raise RuntimeError("Client stdout reader did not stop")
        self.process.stdout.close()
        self.events.close()
        self.stderr.close()


class ScriptedModel:
    def __init__(self):
        self.commands = {}
        self.results = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.send_error(404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path.split("?")[0] == "/v1/messages/count_tokens":
                    self.reply("application/json", json.dumps({"input_tokens": 8}))
                    return
                if self.path.split("?")[0] != "/v1/messages":
                    self.send_error(404)
                    return
                command_id = None
                tail = []
                for message in body.get("messages", []):
                    content = message.get("content", [])
                    for candidate in list(owner.commands):
                        if "AW_MEMORY_PROBE:" + candidate in json.dumps(content):
                            command_id, tail = candidate, []
                    tail.extend(content if isinstance(content, list) else [])
                results = [block for block in tail if isinstance(block, dict)
                           and block.get("type") == "tool_result"]
                block = {"type": "text", "text": "Fixture complete"}
                stop = "end_turn"
                if command_id:
                    if results:
                        owner.results[command_id] = results[-1]
                    else:
                        tool, arguments = owner.commands[command_id]
                        name = "mcp__memory__" + tool
                        if name in {item.get("name") for item in body.get("tools", [])}:
                            block = {"type": "tool_use", "id": "toolu_" + command_id,
                                     "name": name, "input": arguments}
                            stop = "tool_use"
                        else:
                            owner.results[command_id] = {
                                "is_error": True, "content": "MCP tool not advertised"}
                response = {"id": "msg_" + uuid.uuid4().hex, "type": "message",
                            "role": "assistant", "model": body["model"],
                            "content": [block], "stop_reason": stop, "stop_sequence": None,
                            "usage": {"input_tokens": 8, "output_tokens": 12}}
                if not body.get("stream"):
                    self.reply("application/json", json.dumps(response))
                    return
                start = dict(block)
                if stop == "tool_use":
                    start["input"] = {}
                    delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
                else:
                    start["text"] = ""
                    delta = {"type": "text_delta", "text": block["text"]}
                events = [
                    {"type": "message_start", "message": {**response, "content": [], "stop_reason": None}},
                    {"type": "content_block_start", "index": 0, "content_block": start},
                    {"type": "content_block_delta", "index": 0, "delta": delta},
                    {"type": "content_block_stop", "index": 0},
                    {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                     "usage": {"output_tokens": 12}},
                    {"type": "message_stop"},
                ]
                self.reply("text/event-stream", "".join(
                    f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events))

            def reply(self, kind, value):
                data = value.encode()
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Claude:
    def __init__(self, binary, root, url, model):
        self.model = model
        env = isolated_env(root / "claude-home")
        profile = root / "claude-home" / ".claude"
        profile.mkdir()
        env.update({"CLAUDE_CONFIG_DIR": str(profile), "ANTHROPIC_BASE_URL": model.url,
                    "ANTHROPIC_API_KEY": FIXTURE_AUTH,
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"})
        self.version = subprocess.check_output([binary, "--version"], env=env, cwd=root,
                                               text=True, timeout=10).strip()
        (profile / ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "lastOnboardingVersion": self.version.split()[0],
            "autoUpdates": False, "customApiKeyResponses": {"approved": [FIXTURE_AUTH]},
            "projects": {str(root): {"hasTrustDialogAccepted": True}},
        }))
        config = root / "claude-mcp.json"
        config.write_text(json.dumps({"mcpServers": {"memory": {
            "type": "http", "url": url, "headers": {"Authorization": "Bearer " + FIXTURE_AUTH}}}}))
        self.channel = JsonProcess([
            binary, "--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--no-session-persistence", "--model", "claude-sonnet-4-6",
            "--setting-sources", "user", "--strict-mcp-config", "--mcp-config", str(config),
            "--tools", "", "--allowedTools", "mcp__memory__store_memory,mcp__memory__recall_memory",
            "--permission-mode", "dontAsk", "--system-prompt", "Exercise the isolated memory fixture.",
        ], root, env, root / "claude")

    def call(self, tool, arguments):
        key = uuid.uuid4().hex
        self.model.commands[key] = (tool, arguments)
        self.channel.send({"type": "user", "message": {"role": "user", "content":
                           "AW_MEMORY_PROBE:" + key}, "parent_tool_use_id": None, "session_id": ""})
        final = self.channel.wait(lambda message: message.get("type") == "result")
        result = self.model.results.get(key)
        if result is None:
            raise RuntimeError(f"Claude returned without a tool result: {final.get('subtype')}")
        return {"isError": result.get("is_error", False), "content": result.get("content")}

    def close(self):
        self.channel.close()


class Codex:
    def __init__(self, binary, root, url, model):
        env = isolated_env(root / "codex-home")
        profile = root / "codex-home" / ".codex"
        profile.mkdir()
        env["CODEX_HOME"] = str(profile)
        self.version = subprocess.check_output([binary, "--version"], env=env, cwd=root,
                                               text=True, timeout=10).strip()
        (profile / "config.toml").write_text(
            'model_provider = "fixture"\nmodel = "gpt-5.4"\n'
            '[model_providers.fixture]\nname = "Offline fixture"\n'
            f'base_url = "{model.url}/v1"\nwire_api = "responses"\n'
            'requires_openai_auth = false\nsupports_websockets = false\n'
            '[analytics]\nenabled = false\n[mcp_servers.memory]\n'
            f'url = "{url}"\nstartup_timeout_sec = 15\ntool_timeout_sec = 12\n'
            f'[mcp_servers.memory.http_headers]\nAuthorization = "Bearer {FIXTURE_AUTH}"\n')
        self.channel = JsonProcess([binary, "app-server", "--stdio"], root, env, root / "codex")
        self.sequence = 0
        try:
            self.rpc("initialize", {"clientInfo": {"name": "agent-watch-memory-probe", "version": "1"},
                                    "capabilities": {"experimentalApi": True}})
            self.channel.send({"method": "initialized"})
            thread = self.rpc("thread/start", {"modelProvider": "fixture", "model": "gpt-5.4",
                                              "cwd": str(root), "approvalPolicy": "never", "sandbox": "read-only"})
            self.thread_id = thread["thread"]["id"]
        except Exception:
            self.channel.close()
            raise

    def rpc(self, method, params):
        self.sequence += 1
        seq = self.sequence
        self.channel.send({"id": seq, "method": method, "params": params})
        result = self.channel.wait(lambda message: message.get("id") == seq)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    def call(self, tool, arguments):
        return self.rpc("mcpServer/tool/call", {"threadId": self.thread_id, "server": "memory",
                                                "tool": tool, "arguments": arguments})

    def close(self):
        self.channel.close()


class Memory:
    def __init__(self, binary, root, model):
        self.binary, self.root = binary, root
        self.env = isolated_env(root / "memory-home")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        self.url = f"http://127.0.0.1:{port}"
        self.config = root / "memory.env"
        self.config.write_text("# Isolated fixture; all settings are passed explicitly.\n")
        self.env.update({
            "MCP_HTTP_MODE": "http", "MCP_HTTP_HOST": "127.0.0.1", "MCP_HTTP_PORT": str(port),
            "MCP_HTTP_AUTH_TOKEN": FIXTURE_AUTH, "MCP_ROOT": str(root),
            "MCP_ALLOW_DIRS": ".", "MCP_DATA_PATH": str(root / "bank"),
            "MCP_MEMORY_DB_PATH": str(root / "bank" / "memories.db"),
            "MCP_RAG_INDEX_PATH": str(root / "bank" / "index"),
            "MCP_LOG_PATH": str(root / "memory.diagnostics.jsonl"),
            "MCP_RAG_ENABLED": "false", "MCP_MEMORY_ENABLED": "true",
            "MCP_EMBEDDING_MODE": "local-only", "OLLAMA_BASE_URL": model.url,
            "MCP_RAG_AUTO_INDEX": "false", "MCP_RAG_FILE_WATCHER": "false",
            "MCP_SESSION_TRACKING_ENABLED": "false", "MCP_COMPILE_BACKGROUND": "false",
            "MCP_STEWARD_ENABLED": "false", "MCP_ARCHIVE_SWEEP_ENABLED": "false",
            "MCP_SEDIMENT_ENABLED": "false", "MCP_TOOL_GROUPING": "false",
            "MCP_TOOL_PROFILE": "core",
        })
        self.process = None
        self.running_expected = False
        self.log = (root / "memory.stderr").open("x")
        self.pids = []
        self.stops = []

    def start(self):
        self.process = subprocess.Popen([self.binary, "serve", "--config", str(self.config)],
                                        cwd=self.root, env=self.env, stdin=subprocess.DEVNULL,
                                        stdout=self.log, stderr=self.log)
        self.running_expected = True
        self.pids.append(self.process.pid)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Isolated memory server failed; inspect memory.stderr")
            try:
                request = urllib.request.Request(self.url + "/health", headers={
                    "Authorization": "Bearer " + FIXTURE_AUTH})
                with urllib.request.urlopen(request, timeout=1) as response:
                    if json.load(response).get("memory_available"):
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise TimeoutError("Isolated memory bank did not become ready")

    def stop(self, phase="cleanup"):
        if self.process is not None and self.running_expected:
            self.running_expected = False
            started = time.monotonic()
            prior_exit = self.process.poll()
            if prior_exit is not None:
                self.stops.append({"phase": phase, "pid": self.process.pid,
                                   "exit_code": prior_exit, "seconds": 0, "unexpected_exit": True})
                raise RuntimeError(f"Test memory server exited unexpectedly with status {prior_exit}")
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
                raise RuntimeError("Test memory server required forced termination")
            self.stops.append({"phase": phase, "pid": self.process.pid,
                               "exit_code": self.process.returncode,
                               "seconds": round(time.monotonic() - started, 3)})

    def close(self):
        try:
            self.stop()
        finally:
            self.log.close()


def run(args):
    corpus = ConversationCorpus(args.corpus) if args.corpus else None
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    model = memory = claude = codex = None
    report = {"scope": "Claude Code CLI and Codex app-server; no desktop GUI or Keychain test",
              "output": str(root), "checks": [],
              "memory_binary_sha256": hashlib.sha256(args.memory_binary.read_bytes()).hexdigest()}
    context = "aw-memory-" + uuid.uuid4().hex
    markers = {name: "AWMEM" + uuid.uuid4().hex for name in ("claude", "codex", "after_restart")}

    def fact(marker):
        return f"Fixture fact {marker} is synthetic."

    def require(passed):
        if not passed:
            raise RuntimeError("Required connection check failed")

    def call(client, tool, arguments):
        try:
            return client.call(tool, arguments)
        except (RuntimeError, TimeoutError) as error:
            return {"isError": True, "content": str(error)}

    def check(name, result, contains=None, expect_error=False):
        failed = bool(result.get("isError"))
        passed = failed if expect_error else not failed
        if contains is not None:
            passed = passed and contains in json.dumps(result)
        report["checks"].append({"name": name, "passed": passed, "result": result})
        print(("PASS " if passed else "FAIL ") + name, flush=True)
        return passed

    def recall(client, marker):
        return call(client, "recall_memory", {"query": marker, "context": context, "limit": 10})

    def store(client, name):
        return call(client, "store_memory", {"content": fact(markers[name]),
                    "title": f"Shared memory fixture {name}", "type": "semantic", "context": context})

    try:
        model = ScriptedModel()
        memory = Memory(str(args.memory_binary.resolve()), root, model)
        memory.start()
        memory.stop("without_clients")
        memory.start()
        claude = Claude(args.claude, root, memory.url + "/mcp", model)
        codex = Codex(args.codex, root, memory.url + "/mcp", model)
        report["versions"] = {"claude": claude.version, "codex": codex.version,
                              "macos": subprocess.check_output(["sw_vers", "-productVersion"],
                                                                text=True, timeout=10).strip()}
        report["client_pids"] = {"claude": claude.channel.process.pid, "codex": codex.channel.process.pid}
        require(check("claude_writes", store(claude, "claude")))
        require(check("codex_reads_claude", recall(codex, markers["claude"]), fact(markers["claude"])))
        require(check("codex_writes", store(codex, "codex")))
        require(check("claude_reads_codex", recall(claude, markers["codex"]), fact(markers["codex"])))
        if corpus:
            corpus.populate((claude, codex), context)
            corpus.evaluate((("claude", claude), ("codex", codex)), context, "before_restart")
        for cycle, exercise_outage in (("restart", False), ("outage", True)):
            memory.stop(cycle + "_with_clients")
            if exercise_outage:
                with ThreadPoolExecutor(max_workers=2) as pool:
                    jobs = {name: pool.submit(recall, client, markers["claude"])
                            for name, client in (("claude", claude), ("codex", codex))}
                    for name, job in jobs.items():
                        check(name + "_reports_outage", job.result(), expect_error=True)
            memory.start()
            for name, client, marker in (("claude", claude, markers["codex"]),
                                         ("codex", codex, markers["claude"])):
                result = recall(client, marker)
                recovered = check(name + "_" + cycle + "_first_call", result, fact(marker))
                if not recovered:
                    time.sleep(3)
                    result = recall(client, marker)
                    recovered = check(name + "_" + cycle + "_second_call", result, fact(marker))
                if not recovered:
                    raise RuntimeError(name + " could not recover without restarting its process")
            if corpus and cycle == "restart":
                corpus.evaluate((("claude", claude), ("codex", codex)), context, "after_restart")
        require(check("codex_writes_after_recovery", store(codex, "after_restart")))
        require(check("claude_reads_new_record", recall(claude, markers["after_restart"]), fact(markers["after_restart"])))
        with sqlite3.connect((root / "bank" / "memories.db").as_uri() + "?mode=ro", uri=True) as bank:
            rows = bank.execute("SELECT content FROM memories").fetchall()
        expected_contents = [fact(marker) for marker in markers.values()]
        if corpus:
            expected_contents.extend(entry["content"] for entry in corpus.entries)
        require(check("database_matches_expected_records", {"isError":
                      sorted(row[0] for row in rows) != sorted(expected_contents)}))
        report["clients_survived"] = all(client.channel.process.poll() is None for client in (claude, codex))
        require(check("same_client_processes_survived", {"isError": not report["clients_survived"]}))
        report["completed"] = True
    except Exception as error:
        report["completed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
        print(report["error"], flush=True)
    finally:
        for component in (claude, codex, memory, model):
            if component is not None:
                try:
                    component.close()
                except Exception as error:
                    report.setdefault("cleanup_errors", []).append(str(error))
        if memory:
            report["server_pids"] = memory.pids
            report["shutdowns"] = memory.stops
            report["graceful_shutdown_passed"] = bool(memory.stops) and all(
                stop["exit_code"] == 0 and not stop.get("unexpected_exit") for stop in memory.stops)
        report["transport_passed"] = bool(report.get("completed")) and all(
            item["passed"] for item in report["checks"])
        if corpus:
            report["corpus"] = corpus.summary()
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Report: " + str(root / "report.json"), flush=True)
    if not report.get("transport_passed") or report.get("cleanup_errors"):
        return 1
    if corpus and not report["corpus"]["retrieval_passed"]:
        return 3
    return 0 if report.get("graceful_shutdown_passed") else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory-binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for disposable data")
    parser.add_argument("--corpus", type=Path, help="Explicit already-anonymized conversation fixture JSON")
    parser.add_argument("--claude", default=shutil.which("claude"))
    parser.add_argument("--codex", default=shutil.which("codex"))
    options = parser.parse_args()
    if not options.claude or not options.codex or not options.memory_binary.is_file():
        parser.error("Provide existing Claude Code, Codex and Agent Memory executables")
    raise SystemExit(run(options))
