"""Stop one real Claude Code conversation by ID while its Bash tool is running.

The model endpoint is local and deterministic. Only the Bash launch and the
client's session manager matter here. Closing a Claude Desktop tab or detaching
a terminal is a different action.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid


def model_endpoint(command, prompt, follow_up=None):
    class Messages(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path.split("?")[0] != "/v1/messages":
                self.send_error(404)
                return
            messages = body.get("messages", [])
            main_turn = (
                any(tool.get("name") == "Bash" for tool in body.get("tools", []))
                and prompt in json.dumps(messages)
                and not any('"tool_result"' in json.dumps(m) for m in messages)
            )
            next_command = command if main_turn else None
            if not main_turn and follow_up and prompt in json.dumps(messages):
                results = [item for msg in messages for item in msg.get("content", [])
                           if isinstance(item, dict) and item.get("type") == "tool_result"]
                if results:
                    next_command = follow_up(results[-1])
            main_turn = next_command is not None
            block = ({"type": "tool_use", "id": "toolu_followup" if next_command != command else "toolu_fixture", "name": "Bash",
                      "input": {"command": next_command}}
                     if main_turn else {"type": "text", "text": "Done"})
            stop = "tool_use" if main_turn else "end_turn"
            message = {"id": "msg_fixture", "type": "message", "role": "assistant",
                       "model": body["model"], "content": [block], "stop_reason": stop,
                       "stop_sequence": None, "usage": {"input_tokens": 8, "output_tokens": 12}}
            if body.get("stream"):
                start = dict(block)
                if main_turn:
                    start["input"] = {}
                    delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
                else:
                    start["text"] = ""
                    delta = {"type": "text_delta", "text": "Done"}
                events = [
                    {"type": "message_start", "message": dict(message, content=[], stop_reason=None)},
                    {"type": "content_block_start", "index": 0, "content_block": start},
                    {"type": "content_block_delta", "index": 0, "delta": delta},
                    {"type": "content_block_stop", "index": 0},
                    {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                     "usage": {"output_tokens": 12}},
                    {"type": "message_stop"},
                ]
                data = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events)
                kind = "text/event-stream"
            else:
                data, kind = json.dumps(message), "application/json"
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data.encode())))
            self.end_headers()
            self.wfile.write(data.encode())

    return ThreadingHTTPServer(("127.0.0.1", 0), Messages)


def wait_file(path, seconds=120, abort_file=None):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if abort_file is not None and abort_file.exists():
            raise RuntimeError("Test driver ended before requesting chat closure")
        if time.monotonic() >= deadline:
            raise TimeoutError(f"No signal from test driver: {path.name}")
        time.sleep(0.1)


def run(args):
    binary = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not binary:
        raise RuntimeError("Set CLAUDE_BIN to the Claude Code executable or put it on PATH")
    home = args.scratch / "home"
    profile = home / ".claude"
    profile.mkdir(parents=True, exist_ok=False)
    temp = args.scratch / "tmp"
    temp.mkdir()
    prompt = "Run lifecycle fixture " + uuid.uuid4().hex
    server = model_endpoint(args.command, prompt)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    dummy = "fixture-only"
    env = {"HOME": str(home), "CLAUDE_CONFIG_DIR": str(profile), "TMPDIR": str(temp),
           "PATH": os.defpath, "SHELL": "/bin/bash", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
           "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "ANTHROPIC_API_KEY": dummy,
           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_ALLOW_PROTOCOL": "file"}
    def client(*arguments, timeout=25):
        proc = subprocess.run([binary, *arguments], cwd=args.cwd, env=env, stdin=subprocess.DEVNULL,
                              text=True, capture_output=True, timeout=timeout)
        if proc.returncode:
            raise RuntimeError(f"Claude {arguments[0]} exited {proc.returncode}: {(proc.stderr or proc.stdout).strip()}")
        return proc.stdout
    (profile / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "lastOnboardingVersion": client("--version").split()[0],
        "theme": "dark", "autoUpdates": False, "customApiKeyResponses": {"approved": [dummy]},
        "projects": {str(args.cwd): {"hasTrustDialogAccepted": True}},
    }))
    def registered(session):
        rows = json.loads(client("agents", "--json", "--cwd", str(args.cwd)))
        return any(row.get("id") == session and row["cwd"] == str(args.cwd) for row in rows)
    def start(message):
        result = client("--bg", "--setting-sources", "user", "--strict-mcp-config", "--tools", "Bash",
                        "--allowedTools", "Bash", "--permission-mode", "dontAsk", "--", message)
        match = re.search(r"claude attach ([a-f0-9-]+)", result)
        if not match:
            raise RuntimeError(f"No Claude background conversation identifier: {result}")
        return match[1]

    session = None
    witness = None
    try:
        witness = start("Keep this control conversation open.")
        session = start(prompt)
        print(f"Claude Code session {session} started", flush=True)
        if not registered(session):
            raise RuntimeError("Conversation did not become active")
        args.close_file.with_suffix(".ready").touch(exist_ok=False)
        wait_file(args.close_file, abort_file=args.close_file.with_suffix(".done"))
        result = client("stop", session)
        if f"stopped {session}" not in result.lower():
            raise RuntimeError(f"Claude did not acknowledge stop: {result}")
        deadline = time.monotonic() + 10
        while registered(session):
            if time.monotonic() >= deadline:
                raise RuntimeError("Stopped conversation still active")
            time.sleep(0.2)
        session = None
        if not registered(witness):
            raise RuntimeError("The control conversation stopped along with the target")
        print("Claude Code acknowledged stop; the other conversation remains active", flush=True)
        args.close_file.with_suffix(".closed").touch(exist_ok=False)
        wait_file(args.close_file.with_suffix(".done"), 40)
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            stops = {active: pool.submit(client, "stop", active, timeout=10)
                     for active in (session, witness) if active}
            for active, future in stops.items():
                try:
                    future.result()
                except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                    errors.append(f"{active}: {exc}")
        server.shutdown()
        server.server_close()
        if errors:
            message = "Could not stop test conversations: " + "; ".join(errors)
            if not failed:
                raise RuntimeError(message)
            print(message, file=sys.stderr)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--command", required=True)
    for arg in ("cwd", "scratch", "close-file"):
        p.add_argument("--" + arg, type=Path, required=True)
    run(p.parse_args())
