"""Check the installed hook's decisions against local synthetic Git repositories."""

import json
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HOOKS = Path(__file__).resolve().parents[1] / "Resources/GitProtection/hooks"


COMMIT_FORM = (
    "git commit -m \"$(cat <<'EOF'\nDon't break the build\n\nCo-Authored-By: someone\nEOF\n)\""
)

GIT_CASES = [
    # false positives seen in transcripts -> allow
    ("allow", "git push origin feature-x 2>&1 | tail -3", "feat"),
    ("allow", "rm -f /tmp/s.log; git push 2>&1 | tail -3", "feat"),
    ("allow", "docker rm -f pg; git push origin feature-x", "feat"),
    (
        "allow",
        "git commit -q -F - <<'MSG'\nmain carried both; see --force\nMSG\ngit push origin feature-x",
        "feat",
    ),
    (
        "allow",
        "git push -u origin feature-x && glab mr create --source-branch feature-x --target-branch main",
        "feat",
    ),
    ("allow", 'git push 2>&1 | tail -2 && glab api -X POST notes -f "body=$(cat r.md)"', "feat"),
    ("allow", "git push 2>&1 | tail -2; pkill -f sandbox", "feat"),
    ("allow", "# To push without it: SKIP_E2E=1 git push --force\necho hi", "feat"),
    ("allow", "git push --dry-run origin main 2>&1 | tail -18", "feat"),
    (
        "allow",
        "git push origin feature-x:feature-x 2>&1 | tail -1; git diff --shortstat origin/main...HEAD",
        "feat",
    ),
    ("allow", "git checkout -b feature-y main && git push -u origin feature-y", "feat"),
    ("allow", "cd {feat} && git push 2>&1 | tail -3", "main"),
    ("allow", "git log --oneline -1 && git push origin feature-x", "feat"),
    # mentions of a push, not pushes (first full review)
    ("allow", 'grep -rn "git push --force" .', "feat"),
    ("allow", 'echo "never run git push -f here"', "feat"),
    ("allow", 'gh pr create --body "run git push -f later"', "feat"),
    ("allow", 'git commit -m "first line\nsecond line: git push --force is not used"', "feat"),
    ("allow", "pushd {feat} && git push", "main"),
    ("allow", "git push origin --tags", "main"),
    ("allow", "git push origin feature-x && git push origin --tags", "main"),
    ("allow", "git push --no-prune origin", "feat"),
    ("allow", "git push --prune --no-prune origin", "feat"),
    ("allow", "git push --pru --no-pru origin", "feat"),
    ("allow", "git push --prune --dry-run origin", "feat"),
    ("allow", "git push -nf --prune origin", "feat"),
    ("allow", "git push --no-dry-run -n --prune origin", "feat"),
    ("allow", "git push --no-tags --ta origin", "main"),
    # real risky pushes -> ask
    ("deny", "git push --rep origin origin feature-x:main", "feat"),
    ("deny", "git push --repo=origin origin feature-x:main", "feat"),
    ("deny", "git push --rep=origin origin feature-x:main", "feat"),
    ("deny", "git push --repo origin origin feature-x:main", "feat"),
    ("deny", "git push --tags --no-tags origin", "main"),
    ("deny", "git push --tags --no-ta origin", "main"),
    ("deny", "git push --push-o --tags origin", "main"),
    ("deny", "git push --m origin", "feat"),
    ("deny", "git push --force-with-l=feature-x origin feature-x", "feat"),
    ("deny", "git push --push-o --dry-run --prune origin", "feat"),
    ("deny", "git push --push-o=--dry-run --prune origin", "feat"),
    ("deny", "git push -o-n --prune origin", "feat"),
    ("deny", "git push --force -- origin --dry-run", "feat"),
    ("deny", "git push --prune origin", "feat"),
    ("deny", "git push --no-prune --prune origin", "feat"),
    ("deny", "git push --pru origin", "feat"),
    ("deny", "git push --force origin feature-x", "feat"),
    ("deny", "git push -f origin feature-x", "feat"),
    ("deny", "git push --force-with-lease origin feature-x", "feat"),
    ("deny", "git push -uf origin feature-x", "feat"),
    ("deny", "git push origin +feature-x", "feat"),
    ("deny", "git push origin main", "feat"),
    ("deny", "SKIP_E2E=1 git push origin main 2>&1 | tail -25", "feat"),
    ("deny", "git push -u origin main 2>&1 | tail -8", "feat"),
    ("deny", "git push origin main > /tmp/push.log 2>&1", "feat"),
    ("deny", "git push origin HEAD:main", "feat"),
    ("deny", "git push origin feature-x:master", "feat"),
    ("deny", "git push origin HEAD:refs/heads/main", "feat"),
    ("deny", "git push origin --delete main", "feat"),
    ("deny", "git push --all origin", "feat"),
    ("deny", "git -C {feat} push --force", "feat"),
    ("deny", "git push", "main"),
    ("deny", "git push origin 2>&1 | tail -3", "main"),
    (
        "deny",
        "git checkout main 2>&1 | tail -2 && git merge --ff-only x && git push 2>&1 | tail -3",
        "feat",
    ),
    ("deny", "git switch main && git merge --ff-only ci-green && git push origin", "feat"),
    ("deny", "cd {main} && git push 2>&1 | tail -3", "feat"),
    ("deny", "git -C {main} push", "feat"),
    ("deny", "git push --force -u origin main; git push --force -u origin other", "feat"),
    ("deny", "bash -c 'git push -f'", "feat"),
    # the current branch written as HEAD, @ or a substitution (first full review)
    ("deny", "git push -u origin HEAD", "main"),
    ("deny", "git push origin HEAD", "main"),
    ("deny", "git push origin @", "main"),
    ("deny", "git push origin $(git branch --show-current)", "main"),
    ("deny", "git push -o merge_request.create -u origin HEAD", "main"),
    ("allow", "git push -u origin HEAD", "feat"),
    # deleting on the remote: asked for main/master and for what may be a tag
    ("deny", "git push origin --delete widget-row-redesign 2>&1 | tail -3", "feat"),
    ("deny", "git push -d origin feature-x", "feat"),
    ("deny", "git push origin :old-feature", "feat"),
    ("allow", "git push origin v0.1.0 2>&1 | tail -3", "feat"),
    ("deny", "git branch -d gone-branch && git push origin --delete gone-branch", "feat"),
    ("deny", "git push origin :master", "feat"),
    ("deny", "git push origin --delete v1.2.0", "feat"),
    ("deny", "git push origin :refs/tags/nightly", "feat"),
    ("deny", "git push --delete origin tag nightly", "feat"),
    ("deny", "git tag -d nightly && git push origin :nightly", "feat"),
    ("deny", "git push origin -d local-tag", "feat"),
    ("deny", "git push origin --delete nightly", "feat"),
    ("deny", "git push --delete origin latest", "feat"),
    ("deny", "git push origin --delete v2", "feat"),
    # a heredoc inside $(…), a reserved word or a group before the push (full review)
    ("deny", COMMIT_FORM + " && git push origin main", "feat"),
    ("deny", COMMIT_FORM + " && git push --force origin feature-x", "feat"),
    ("deny", "if true; then git push --force origin x; fi", "feat"),
    ("deny", "if git diff --quiet; then git push origin main; fi", "feat"),
    ("deny", "{ git push -f origin x; }", "feat"),
    ("deny", "! git push -f origin x", "feat"),
    ("deny", "for r in a b; do git push origin main; done", "feat"),
    ("deny", "if true; then git push; fi", "main"),
    # a cd ends with its subshell; --git-dir and GIT_DIR name the repository (verification)
    ("allow", "(cd {main} && git fetch); git push", "feat"),
    ("deny", "sh -c 'cd {main} && git push'", "feat"),
    ("deny", "(cd {main} && git push)", "feat"),
    ("deny", "git --git-dir={main}/.git push", "feat"),
    ("deny", "git --git-dir {main}/.git push", "feat"),
    ("deny", "GIT_DIR={main}/.git git push", "feat"),
    ("deny", "env GIT_DIR={main}/.git git push", "feat"),
    ("deny", "git -C {main} --git-dir=.git push", "feat"),
    ("allow", "git --git-dir={feat}/.git push", "main"),
    # launchers, git's own options, matching refspecs, --track (full review)
    ("deny", "docker run img sh -c 'git push -f'", "feat"),
    ("deny", "env -S 'git push --force origin x'", "feat"),
    ("deny", "fish -c 'git push -f'", "feat"),
    ("deny", "ssh host bash -s <<'EOF'\ngit push --force origin x\nEOF", "feat"),
    ("deny", "git submodule foreach git push origin main", "feat"),
    ("deny", "git --git-dir {feat}/.git push origin main", "feat"),
    ("deny", "git --work-tree /tmp push origin main", "feat"),
    ("deny", "git push origin 'refs/heads/*:refs/heads/*'", "feat"),
    ("deny", "git push origin :", "feat"),
    ("deny", "git push origin HEAD:heads/main", "feat"),
    ("deny", "git checkout --track origin/main && git push", "feat"),
    ("deny", "git push origin --delete refs/heads/feature-y", "feat"),
    # a tag deleted locally, then on the remote, under a name that is also a branch
    ("deny", "git tag -d widget-row-redesign && git push origin :widget-row-redesign", "feat"),
    # CRLF line ends: a carriage return must not hide the branch
    ("deny", "git push origin main\r\necho done", "feat"),
]

class GitGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(tempfile.mkdtemp(prefix="agent-watch-hook-")).resolve()
        cls.addClassCleanup(subprocess.run, ["/usr/bin/trash", str(root)], check=True)
        cls.env = {"HOME": str(root), "PATH": os.defpath, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ALLOW_PROTOCOL": "file"}
        contents = root / "Example Application.app/Contents"
        hooks = contents / "Resources/GitProtection/hooks"
        shutil.copytree(HOOKS, hooks, ignore=shutil.ignore_patterns("__pycache__"))
        cls.hook = hooks / "git_guard.py"
        spec = importlib.util.spec_from_file_location("git_guard", hooks / "git_guard.py")
        cls.guard = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.guard
        cls.addClassCleanup(sys.modules.pop, spec.name)
        spec.loader.exec_module(cls.guard)
        cls.cli = contents / "MacOS/AgentWatchGit"
        cls.folders = {"feat": root / "feat", "main": root / "main"}
        def git(repo, *arguments):
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test",
                            "-c", "user.email=fixture@example.invalid", *arguments],
                           env=cls.env, capture_output=True, check=True, timeout=10)
        for repo in cls.folders.values():
            repo.mkdir()
            git(repo, "init", "--template=", "-b", "main")
            git(repo, "commit", "--allow-empty", "-m", "Fixture")
        feature = cls.folders["feat"]
        git(feature, "switch", "-c", "feature-x")
        git(feature, "tag", "local-tag")
        for branch in ("widget-row-redesign", "old-feature", "feature-x"):
            git(feature, "update-ref", "refs/remotes/origin/" + branch, "HEAD")

    def invoke(self, host, payload):
        argv = [sys.executable, "-I", "-B", "-S", str(self.hook)]
        if host == "codex":
            argv += ["--host", "codex"]
        return subprocess.run(argv, env=self.env, cwd=self.folders["feat"], input=payload,
                              text=True, capture_output=True, check=True, timeout=10).stdout

    def test_shell_decisions(self):
        with patch.dict(os.environ, self.env, clear=True):
            for want, command, folder in GIT_CASES:
                for key, path in self.folders.items():
                    command = command.replace("{" + key + "}", str(path))
                with self.subTest(command=command):
                    answer = self.guard.inspect({"cwd": str(self.folders[folder]),
                                                 "tool_input": {"command": command}})
                    if want == "allow":
                        self.assertEqual(answer, "")
                    else:
                        verdict = json.loads(answer)["hookSpecificOutput"]
                        self.assertEqual(verdict["hookEventName"], "PreToolUse")
                        self.assertEqual(verdict["permissionDecision"], "deny")

    def test_both_hook_invocations_direct_deletion_to_the_bundled_cli(self):
        for host in ("claude", "codex"):
            with self.subTest(host=host):
                answer = self.invoke(host, json.dumps({"tool_input": {"command": "git push origin --delete topic"}}))
                verdict = json.loads(answer)["hookSpecificOutput"]
                self.assertEqual(verdict["permissionDecision"], "deny")
                self.assertIn(shlex.quote(str(self.cli)) + " push", verdict["permissionDecisionReason"])
                self.assertIn("delete to true", verdict["permissionDecisionReason"])
                self.assertEqual(self.invoke(host, json.dumps({"tool_input": {"command": "git branch topic"}})), "")

    def test_uses_shell_tool_working_folder(self):
        payload = json.dumps({"cwd": str(self.folders["feat"]), "tool_input": {
            "cmd": "git push", "workdir": str(self.folders["main"])}})
        self.assertEqual(json.loads(self.invoke("codex", payload))["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_install_preflight_finishes_without_reading_stdin(self):
        proc = subprocess.Popen([sys.executable, self.hook, "--check"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        try:
            self.assertEqual(proc.wait(timeout=3), 0)
            self.assertEqual(proc.stdout.read(), b"agent-watch-git-hook-ok\n")
            self.assertEqual(proc.stderr.read(), b"")
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.communicate()

    def test_unreadable_input_fails_closed(self):
        self.assertEqual(json.loads(self.invoke("claude", "invalid"))["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_unknown_current_branch_blocks_implicit_push(self):
        payload = json.dumps({"cwd": str(self.folders["feat"].parent), "tool_input": {"command": "git push"}})
        for host in ("claude", "codex"):
            with self.subTest(host=host):
                decision = json.loads(self.invoke(host, payload))["hookSpecificOutput"]
                self.assertEqual(decision["permissionDecision"], "deny")
                self.assertIn("current branch could not be determined", decision["permissionDecisionReason"])

    def test_implicit_push_with_configured_destination_requires_confirmation(self):
        folder = self.folders["feat"]
        config = ["git", "-C", str(folder), "config"]
        subprocess.run(config + ["--local", "remote.example.push", "HEAD:refs/heads/main"],
                       env=self.env, check=True, timeout=10)
        try:
            for command in ("git push", "git push example", "git push --repo=example",
                            "git push example feature-x", "git push --repo=origin example"):
                with self.subTest(command=command):
                    payload = json.dumps({"cwd": str(folder), "tool_input": {"command": command}})
                    decision = json.loads(self.invoke("codex", payload))["hookSpecificOutput"]
                    self.assertEqual(decision["permissionDecision"], "deny")
                    self.assertIn("depends on Git configuration", decision["permissionDecisionReason"])
        finally:
            subprocess.run(config + ["--local", "--unset", "remote.example.push"],
                           env=self.env, check=True, timeout=10)

    def test_remote_mirror_setting_requires_confirmation(self):
        folder = self.folders["feat"]
        config = ["git", "-C", str(folder), "config"]
        subprocess.run(config + ["--local", "remote.example.mirror", "true"],
                       env=self.env, check=True, timeout=10)
        try:
            payload = json.dumps({"cwd": str(folder), "tool_input": {"command": "git push example"}})
            decision = json.loads(self.invoke("claude", payload))["hookSpecificOutput"]
            self.assertEqual(decision["permissionDecision"], "deny")
            self.assertIn("mirror push", decision["permissionDecisionReason"])
        finally:
            subprocess.run(config + ["--local", "--unset", "remote.example.mirror"],
                           env=self.env, check=True, timeout=10)

    def test_source_only_push_with_upstream_default_requires_confirmation(self):
        folder = self.folders["feat"]
        config = ["git", "-C", str(folder), "config", "--local"]
        subprocess.run(config + ["push.default", "upstream"], env=self.env, check=True, timeout=10)
        try:
            payload = json.dumps({"cwd": str(folder), "tool_input": {"command": "git push origin feature-x"}})
            decision = json.loads(self.invoke("codex", payload))["hookSpecificOutput"]
            self.assertEqual(decision["permissionDecision"], "deny")
            self.assertIn("depends on Git configuration", decision["permissionDecisionReason"])
        finally:
            subprocess.run(config + ["--unset", "push.default"], env=self.env, check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
