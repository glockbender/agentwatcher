"""Replace an installed Agent Watch bundle and exercise the same registered hooks in both clients."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

import claude
import codex
from run import git_environment, prepare, processes, require_graphical_mac, snapshot, windows


def checked(*args, **kw):
    return subprocess.check_output(args, text=True, timeout=90, **kw).strip()


async def codex_trust(env, repo, first_install):
    server = await asyncio.create_subprocess_exec(
        env["CODEX_BIN"], "app-server", "--stdio", cwd=repo, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        await codex.rpc(server, 1, "initialize", {"clientInfo": {"name": "aw-fixture", "version": "1"},
                                                  "capabilities": {"experimentalApi": True}})
        server.stdin.write(b'{"method":"initialized"}\n')
        listing = await codex.rpc(server, 2, "hooks/list", {"cwds": [str(repo)]})
        entry, = listing["data"]
        if entry["errors"]:
            raise RuntimeError(entry["errors"])
        hook, = [h for h in entry["hooks"] if "git-guard.sh" in h.get("command", "")]
        identity = (hook["key"], hook["currentHash"])
        if first_install:
            if hook["trustStatus"] != "untrusted":
                raise RuntimeError(f"Unexpected initial hook trust: {hook['trustStatus']}")
            # Model the user's one-time acceptance through the client's own configuration API.
            await codex.rpc(server, 3, "config/value/write", {
                "keyPath": "hooks.state", "value": {identity[0]: {"trusted_hash": identity[1]}},
                "mergeStrategy": "upsert"})
        elif hook["trustStatus"] != "trusted" or not hook["enabled"]:
            raise RuntimeError(f"Codex hook inactive after registration: {hook}")
        return identity
    finally:
        server.stdin.close()
        await asyncio.wait_for(server.wait(), 15)


def exercise(client, env, bundle, repo, branch, probe, *, expect_missing_hook=False):
    binary = bundle / "Contents/MacOS/AgentWatchGit"
    args = {"repository": str(repo), "remote": "origin", "destination": "refs/heads/" + branch,
            "delete": True, "reason": "Check the disposable project rule."}
    prompt = "Run the Agent Watch fixture operation."
    raw = "git push origin --delete " + branch
    denial = []
    def follow_up(result):
        if denial:
            return None
        denial.append(json.dumps(result, ensure_ascii=False))
        if str(binary) in denial[0] and "push" in denial[0]:
            return shlex.join([str(binary), "push", json.dumps(args)])
        return None

    if client == "claude":
        model = claude.model_endpoint(raw, prompt, follow_up)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        env = dict(env, ANTHROPIC_BASE_URL=f"http://127.0.0.1:{model.server_port}")
        invocation = [env["CLAUDE_BIN"], "-p", "--setting-sources", "user", "--strict-mcp-config",
                      "--tools", "Bash", "--allowedTools", "Bash", "--permission-mode", "dontAsk", "--", prompt]
    else:
        model = codex.model_server(raw, follow_up)
        url = f"http://127.0.0.1:{model.server_port}/v1"
        invocation = [env["CODEX_BIN"], "exec", "-c", 'model_provider="fixture"', "-c", 'model="gpt-5.4"',
                      "-c", 'model_providers.fixture.name="Fixture"', "-c", f'model_providers.fixture.base_url="{url}"',
                      "-c", 'model_providers.fixture.wire_api="responses"', "-c",
                      'model_providers.fixture.requires_openai_auth=false', "-c",
                      'model_providers.fixture.supports_websockets=false', "-s", "danger-full-access", prompt]
    log = repo.parent / f"{client}.log"
    with log.open("w") as output:
        proc = subprocess.Popen(invocation, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if expect_missing_hook and denial and "the installed hook could not run" in denial[0]:
                    print(f"{client}: the registered hook denied while its bundle was unavailable", flush=True)
                    return
                if (denial and str(binary) not in denial[0]) or proc.poll() is not None:
                    raise RuntimeError(f"{client}: hook did not direct the client to the CLI: {denial[:1]}; see {log}")
                rows = processes()
                for pid, (parent, exe) in rows.items():
                    if exe != str(binary) or rows.get(parent, (0, ""))[1] != exe or not windows(probe, pid):
                        continue
                    command = checked("ps", "-ww", "-p", str(pid), "-o", "command=")
                    message = json.loads(command.split(" --confirmation-window ", 1)[1])["message"]
                    expected = "Шаг 1 из 2: Удаление защищённой ветки" if branch == "release" else "Шаг 1 из 1: Удаление обычной ветки"
                    if not denial or not message.startswith(expected) or branch not in message:
                        raise RuntimeError(f"Unexpected {client} confirmation for {branch}: {message}")
                    print(f"{client}: {branch}: {expected}", flush=True)
                    return
                time.sleep(0.25)
            raise TimeoutError(f"No visible confirmation for {client}, {branch}; hook reply: {denial[:1]}; see {log}")
        finally:
            for pid, (_, exe) in processes().items():
                if exe == str(binary):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            if client == "codex":
                model.finished.set()
            model.shutdown()
            model.server_close()


def run(args):
    require_graphical_mac()
    root = Path(tempfile.mkdtemp(prefix="aw-upgrade-", dir="/private/tmp"))
    fixture = root / "git"
    prepare(fixture)
    git, env = git_environment(fixture)
    repo = fixture / "project"
    refs = snapshot(fixture, git, env)
    marker = root / "push-attempted"
    receiver = fixture / "remote.git/hooks/pre-receive"
    receiver.parent.mkdir(exist_ok=True)
    receiver.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 1\n")
    receiver.chmod(0o700)
    home = Path(env["HOME"])
    profiles = {c: home / ("." + c) for c in ("claude", "codex")}
    for profile in profiles.values():
        profile.mkdir()
    env.update(CLAUDE_CONFIG_DIR=str(profiles["claude"]), CODEX_HOME=str(profiles["codex"]),
               SHELL="/bin/bash", TERM="xterm-256color", LANG="en_US.UTF-8", ANTHROPIC_API_KEY="fixture-only",
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1")
    for c in profiles:
        key = c.upper() + "_BIN"
        env[key] = os.environ.get(key) or shutil.which(c) or c
        print(checked(env[key], "--version", env=env), flush=True)
    (profiles["claude"] / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "theme": "dark", "autoUpdates": False,
        "customApiKeyResponses": {"approved": ["fixture-only"]}, "projects": {str(repo): {"hasTrustDialogAccepted": True}}}))
    config = profiles["codex"] / "config.toml"
    config.write_text('[analytics]\nenabled = false\n')
    install = root / "Test Applications"
    install.mkdir()
    bundle = install / "AgentWatch.app"
    checked("ditto", args.previous_bundle or args.bundle, bundle)
    info = bundle / "Contents/Info.plist"
    if args.previous_bundle is None:
        old = plistlib.loads(info.read_bytes())
        old["CFBundleVersion"] = "1"
        info.write_bytes(plistlib.dumps(old))
        with (bundle / "Contents/Resources/GitProtection/hooks/git-guard.sh").open("a") as script:
            script.write("\n# Previous release fixture\n")
        checked("codesign", "-f", "-s", "-", bundle)
    def verify():
        checked("codesign", "--verify", "--deep", "--strict", bundle)
    verify()
    exe = bundle / "Contents/MacOS/AgentWatch"
    files = [repo / ".git/config", config]
    for c, profile in profiles.items():
        path = profile / ("settings.json" if c == "claude" else "hooks.json")
        initial = {"hooks": {"SessionStart": []}}
        if c == "claude":
            initial["env"] = {"DISABLE_AUTOUPDATER": "1"}
        path.write_text(json.dumps(initial))
        if checked(exe, "--git-hooks", "install", c, profile, env=env) != "registered":
            raise RuntimeError(f"Failed to install {c} hook")
        files.append(path)
    identity = asyncio.run(codex_trust(env, repo, True))
    def contents(path):
        return json.loads(path.read_bytes()) if path.suffix == ".json" else path.read_bytes()
    state = [contents(p) for p in files]
    def check(phase, branches):
        print(phase, flush=True)
        if asyncio.run(codex_trust(env, repo, False)) != identity:
            raise RuntimeError("Codex hook identity changed")
        for c in profiles:
            for branch in branches:
                exercise(c, env, bundle, repo, branch, args.windows)
                if snapshot(fixture, git, env) != refs or marker.exists():
                    raise RuntimeError("The attempted deletion reached the local Git receiver")
        if [contents(p) for p in files] != state:
            changed = [str(p) for p, saved in zip(files, state) if contents(p) != saved]
            raise RuntimeError(f"Profile or rule was rewritten: {changed}")
    check("Before bundle replacement", ["release"])
    before_update = [p.read_bytes() for p in files]
    bundle.rename(root / "old.app")
    checked("ditto", args.bundle, bundle)
    verify()
    seal = Path("Contents/_CodeSignature/CodeResources")
    if (bundle / seal).read_bytes() == (root / "old.app" / seal).read_bytes():
        raise RuntimeError("Use distinct signed application bundles")
    for client, profile in profiles.items():
        if checked(exe, "--git-hooks", "status", client, profile, env=env) != "registered":
            raise RuntimeError(f"The updated installer lost the {client} registration")
    check("After bundle replacement, without reinstalling hooks", ["release", "feature/example"])
    unavailable = root / "temporarily unavailable.app"
    bundle.rename(unavailable)
    try:
        for client in profiles:
            exercise(client, env, bundle, repo, "feature/example", args.windows, expect_missing_hook=True)
            if snapshot(fixture, git, env) != refs or marker.exists():
                raise RuntimeError("An unavailable bundle let the attempted deletion reach Git")
    finally:
        unavailable.rename(bundle)
    if [p.read_bytes() for p in files] != before_update:
        raise RuntimeError("Bundle replacement or the first new chat changed profile bytes")
    print("PASS: both clients retained their hooks and project rule; profiles and remote refs unchanged.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--previous-bundle", type=Path, default=os.getenv("AGENT_WATCH_PREVIOUS_BUNDLE"), help="Optional earlier bundle with the standalone Git hook")
    parser.add_argument("--windows", required=True, type=Path)
    run(parser.parse_args())
