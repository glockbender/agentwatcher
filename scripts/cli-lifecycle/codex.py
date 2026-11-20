"""Archive one active Codex chat using its app-server protocol, with an offline model."""

import argparse
import asyncio
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def model_server(command, follow_up=None):
    # Only the model's response is scripted. Codex constructs, starts, and owns the tool call.
    class Model(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if self.path.rstrip("/") != "/v1/responses":
                self.send_error(404)
                return
            body = self.rfile.read(int(self.headers["Content-Length"]))
            request = json.loads(body)
            tools = {t.get("name") for t in request.get("tools", [])}
            if "exec_command" not in tools:
                self.send_error(400, "Codex did not advertise exec_command")
                print("Codex advertised:", sorted(t for t in tools if t), flush=True)
                return
            response = {"id": "resp_fixture", "object": "response", "status": "completed",
                        "model": "gpt-5.4", "output": [], "usage": {
                            "input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
            next_command = command
            if getattr(self.server, "issued", False):
                outputs = [item for item in request.get("input", [])
                           if isinstance(item, dict) and item.get("type") == "function_call_output"]
                next_command = follow_up(outputs[-1]) if follow_up and outputs else None
                if next_command is None:
                    self.server.finished.wait(180)
                    return
            self.server.issued = True
            suffix = "fixture" if next_command == command else "followup"
            call = {"type": "function_call", "id": "fc_" + suffix, "call_id": "call_" + suffix,
                    "name": "exec_command", "arguments": json.dumps(
                        {"cmd": next_command, "yield_time_ms": 1000, "login": False})}
            events = [
                {"type": "response.created", "response": {**response, "status": "in_progress"}},
                {"type": "response.output_item.added", "output_index": 0, "item": {**call, "arguments": ""}},
                {"type": "response.output_item.done", "output_index": 0, "item": call},
                {"type": "response.completed", "response": {**response, "output": [call]}},
            ]
            data = "".join("event: " + e["type"] + "\ndata: " + json.dumps(e) + "\n\n" for e in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = HTTPServer(("127.0.0.1", 0), Model)
    server.finished = threading.Event()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


async def rpc(server, seq, method, params):
    print(f"Codex request: {method}", flush=True)
    request = {"method": method, "id": seq, "params": params}
    server.stdin.write((json.dumps(request) + "\n").encode())
    await server.stdin.drain()
    timeout = 120 if method == "initialize" else 40
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        try:
            raw = await asyncio.wait_for(server.stdout.readline(), deadline - asyncio.get_running_loop().time())
        except asyncio.TimeoutError:
            raise RuntimeError(f"Codex did not acknowledge {method} within {timeout}s") from None
        if not raw:
            raise RuntimeError(f"Codex stopped before acknowledging {method}")
        reply = json.loads(raw)
        if reply.get("id") == seq:
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error']}")
            return reply["result"]
        if reply.get("method") == "error":
            print("Codex error:", reply.get("params", {}).get("error"), flush=True)


def diagnostic(log):
    log.seek(max(0, os.fstat(log.fileno()).st_size - 4096))
    text = re.sub(r"\x1b\[[0-9;]*m", "", log.read(4096).decode(errors="replace"))
    lines = [line for line in text.splitlines()
             if not re.search(r"(?i)authorization|bearer|api[ _-]?key|secret|password|token|sk-", line)]
    return "\n".join(lines[-4:])[-900:] or "(no diagnostic in stderr)"


async def wait_for(path, process, stop=None):
    for _ in range(1800):
        if stop is not None and stop.exists():
            raise RuntimeError("Fixture ended before requesting a chat archive")
        if path.exists():
            return
        if process.returncode is not None:
            raise RuntimeError("Codex exited before the fixture finished")
        await asyncio.sleep(0.1)
    raise TimeoutError(f"Waiting for {path.name}")


async def probe(args):
    for marker in [args.close_file, *(args.close_file.with_suffix(x) for x in (".done", ".closed", ".ready"))]:
        if marker.exists():
            raise ValueError(f"Stale fixture marker: {marker}")
    scratch = args.scratch.resolve()
    scratch.mkdir(exist_ok=True)
    home = scratch / "home"
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True, exist_ok=False)
    tmp = scratch / "tmp"
    tmp.mkdir()
    model = model_server(args.command)
    port = model.server_address[1]
    (codex_home / "config.toml").write_text(
        f'model_provider = "fixture"\nmodel = "gpt-5.4"\n'
        f'[model_providers.fixture]\nname = "Local fixture"\nbase_url = "http://127.0.0.1:{port}/v1"\n'
        'wire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\n'
        '[analytics]\nenabled = false\n')
    env = {"HOME": str(home), "CODEX_HOME": str(codex_home), "TMPDIR": str(tmp),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/bash",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ALLOW_PROTOCOL": "file",
           "GIT_TERMINAL_PROMPT": "0", "LANG": "C"}
    codex = os.environ.get("CODEX_BIN") or shutil.which("codex")
    if not codex:
        raise RuntimeError("Set CODEX_BIN to the path of the Codex executable")
    with (scratch / "codex.stderr").open("x+b") as log:
        server = await asyncio.create_subprocess_exec(
            codex, "app-server", "--stdio", cwd=args.cwd, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=log, limit=4 * 1024 * 1024)
        try:
            await rpc(server, 1, "initialize", {"clientInfo": {"name": "agent-watch-probe", "version": "1"}})
            server.stdin.write(b'{"method":"initialized"}\n')
            thread = await rpc(server, 2, "thread/start", {
                "modelProvider": "fixture", "model": "gpt-5.4", "cwd": str(args.cwd.resolve()),
                "approvalPolicy": "never", "sandbox": "danger-full-access"})
            thread_id = thread["thread"]["id"]
            await rpc(server, 3, "turn/start", {"threadId": thread_id,
                "input": [{"type": "text", "text": "Run the fixture command once."}]})
            print("Started Codex turn", thread_id, flush=True)
            args.close_file.with_suffix(".ready").touch(exist_ok=False)
            await wait_for(args.close_file, server, stop=args.close_file.with_suffix(".done"))
            if not getattr(model, "issued", False):
                raise RuntimeError("A close request arrived before the fixture tool was issued")
            await rpc(server, 4, "thread/archive", {"threadId": thread_id})
            archived = await rpc(server, 5, "thread/list", {
                "archived": True, "modelProviders": ["fixture"], "limit": 100})
            if thread_id not in {t["id"] for t in archived["data"]}:
                raise RuntimeError("Codex acknowledged archive but did not list the archived chat")
            print("Archived the active chat via thread/archive. Codex app-server is still running.", flush=True)
            args.close_file.with_suffix(".closed").touch(exist_ok=False)
            await wait_for(args.close_file.with_suffix(".done"), server)
        except (RuntimeError, OSError, asyncio.TimeoutError) as exc:
            print(f"Codex app-server status={server.returncode}, stderr: {diagnostic(log)}", flush=True)
            raise SystemExit(str(exc)) from None
        finally:
            model.finished.set()
            model.shutdown()
            model.server_close()
            if server.returncode is None:
                server.terminate()
            try:
                await asyncio.wait_for(server.wait(), 4)
            except asyncio.TimeoutError:
                server.kill()
                await server.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", required=True)
    for option in ("--cwd", "--scratch", "--close-file"):
        parser.add_argument(option, required=True, type=Path)
    asyncio.run(probe(parser.parse_args()))
