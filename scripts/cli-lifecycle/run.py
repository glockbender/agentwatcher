"""Exercise chat closure in a disposable macOS guest with its own graphical login."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from desktop_git_fixture import git_environment, prepare, snapshot


def require_graphical_mac():
    if sys.platform != "darwin":
        raise SystemExit("This fixture requires macOS.")
    guest = subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], text=True).strip() == "1"
    if not guest and os.environ.get("AGENT_WATCH_HOST_GUI_FIXTURES") != "1":
        raise SystemExit("Use a disposable macOS guest or explicitly enable the isolated host fixtures.")
    if os.stat("/dev/console").st_uid != os.getuid():
        raise SystemExit("Run the fixture from the account logged into the graphical session.")


def processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True, timeout=20)
    rows = (line.strip().split(None, 2) for line in output.splitlines())
    return {int(pid): (int(parent), name) for pid, parent, name in rows}


def wait_for(description, read, client, seconds):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if client.poll() is not None:
            raise RuntimeError(f"Adapter exited before {description} (status {client.returncode})")
        value = read()
        if value:
            return value
        time.sleep(0.25)
    raise RuntimeError(f"Timed out waiting for {description}")


def windows(probe, pid):
    return subprocess.check_output([probe, str(pid)], text=True, timeout=15).splitlines()


def exercise(args, root):
    fixture = root / "git"
    prepare(fixture)
    git, env = git_environment(fixture)
    before = snapshot(fixture, git, env)
    repo = fixture / "project"
    # A private executable path identifies exactly this run even after a child is reparented.
    binary = root / "agent-watch-git"
    shutil.copy2(args.binary, binary)
    request = {"repository": str(repo), "remote": "origin", "destination": "refs/heads/feature/example",
               "delete": True, "reason": "Test cancelling the chat before confirming deletion."}
    command = shlex.join([str(binary), "push", json.dumps(request)])
    close = root / "close"
    command_line = [sys.executable, str(HERE / (args.client + ".py")), "--command", command,
                    "--cwd", str(repo), "--scratch", str(root / "client"), "--close-file", str(close)]
    adapter = subprocess.Popen(command_line)
    try:
        def alert():
            rows = processes()
            for pid, (parent, exe) in rows.items():
                if exe == str(binary) and rows.get(parent, (None, None))[1] == exe:
                    seen = windows(args.windows, pid)
                    if seen:
                        return parent, pid, seen
            return None

        wait_for("the client to be ready to close this chat", close.with_suffix(".ready").exists, adapter, 210)
        parent, child, numbers = wait_for("a visible confirmation owned by the Rust CLI", alert, adapter, 120)
        print(f"Before close: CLI={parent}, window process={child}, window IDs={numbers}", flush=True)
        time.sleep(0.4)
        if alert() != (parent, child, numbers):
            raise RuntimeError("The confirmation disappeared before asking the client to close the chat")
        close.touch(exist_ok=False)
        wait_for("the client's close acknowledgement", close.with_suffix(".closed").exists, adapter, 45)
        end = time.monotonic() + 10
        while True:
            if adapter.poll() is not None:
                raise RuntimeError("Adapter exited before assertions")
            remaining = [pid for pid, (_, exe) in processes().items() if exe == str(binary)]
            shown = windows(args.windows, child)
            if (not remaining and not shown) or time.monotonic() >= end:
                break
            time.sleep(0.25)
        intact = snapshot(fixture, git, env) == before
        print(f"After close: all remote refs unchanged={intact}, window IDs={shown}, CLI/helper PIDs={remaining}",
              flush=True)
        if remaining or shown or not intact:
            raise RuntimeError("Chat closure did not satisfy the cancellation contract")
    finally:
        # The adapter may stop its client only after the verdict has been collected.
        primary_error = sys.exc_info()[0] is not None
        close.with_suffix(".done").touch()
        try:
            status = adapter.wait(timeout=35)
        except subprocess.TimeoutExpired:
            adapter.kill()
            adapter.wait()
            status = adapter.returncode
            if not primary_error:
                raise RuntimeError("Adapter did not stop after the test")
        finally:
            for pid, (_, exe) in processes().items():
                if exe == str(binary):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
    if status:
        raise RuntimeError(f"Adapter failed with status {status}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", choices=("claude", "codex"))
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--windows", required=True, type=Path, help="Compiled windows.swift")
    args = parser.parse_args()
    require_graphical_mac()
    root = Path(tempfile.mkdtemp(prefix="aw-close-", dir="/private/tmp"))
    try:
        exercise(args, root)
    except Exception:
        print(f"Failed fixture retained: {root}", file=sys.stderr)
        raise
    else:
        subprocess.run(["/usr/bin/trash", str(root)], check=True, timeout=15)
