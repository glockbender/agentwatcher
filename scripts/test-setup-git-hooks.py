"""`task setup` against throwaway repositories: each worktree runs the gates of its own branch."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "setup-git-hooks.py"
GATES = Path(__file__).resolve().parents[1] / ".githooks"
FAKE_TASK = '#!/bin/sh\necho "task $* GIT_DIR=${GIT_DIR-unset} GIT_INDEX_FILE=${GIT_INDEX_FILE-unset}" >> "$HOOK_LOG"\n'

PRE_COMMIT = '#!/bin/sh\necho "{label} pre-commit" >> "$HOOK_LOG"\n'
PRE_PUSH = (
    "#!/bin/sh\n"
    "read -r _local_ref _local_sha remote_ref _remote_sha\n"
    'echo "{label} pre-push $1 $remote_ref" >> "$HOOK_LOG"\n'
)


class Repository:
    """A repository whose `main` and `other` branches carry hooks that write their own name.

    `main` is checked out in the main checkout and `other` in a linked worktree beside it.
    """

    def __init__(self, base: Path):
        self.base = base
        self.log = base / "hooks.log"
        config = base / "gitconfig"
        config.write_text(
            "[user]\n\tname = Test\n\temail = test@example.invalid\n"
            "[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n"
        )
        # The gate runs these tests inside a commit, where GIT_DIR and GIT_INDEX_FILE name the
        # real repository. Left in place, they would point every command here at it.
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1", HOOK_LOG=str(self.log))

        self.main = base / "main"
        self.worktree = base / "worktree"
        self.git(base, "init", "--quiet", "--bare", "remote.git")
        self.git(base, "init", "--quiet", "main")
        self.git(self.main, "remote", "add", "origin", str(base / "remote.git"))
        self.write_hooks("main")
        self.git(self.main, "commit", "--quiet", "--no-verify", "-m", "main hooks")
        self.git(self.main, "switch", "--quiet", "-c", "other")
        self.write_hooks("other")
        self.git(self.main, "commit", "--quiet", "--no-verify", "-am", "other hooks")
        self.git(self.main, "switch", "--quiet", "main")
        self.git(self.main, "worktree", "add", "--quiet", str(self.worktree), "other")
        self.common = self.main / ".git"

    def run(self, folder: Path, *command: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            command, cwd=folder, env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True
        )

    def git(self, folder: Path, *arguments: str) -> str:
        result = self.run(folder, "git", *arguments)
        if result.returncode != 0:
            raise AssertionError(f"git {' '.join(arguments)}: {result.stderr}")
        return result.stdout.strip()

    def write_hooks(self, label: str) -> None:
        hooks = self.main / ".githooks"
        hooks.mkdir(exist_ok=True)
        for name, text in (("pre-commit", PRE_COMMIT), ("pre-push", PRE_PUSH)):
            (hooks / name).write_text(text.format(label=label))
            (hooks / name).chmod(0o755)
        self.git(self.main, "add", ".githooks")

    def pin_like_claude(self) -> None:
        """What Claude Code and the Claude desktop app leave after creating a worktree."""
        pinned = str(self.main / ".githooks")
        self.git(self.main, "config", "extensions.worktreeConfig", "true")
        self.git(self.main, "config", "core.hooksPath", pinned)
        self.git(self.worktree, "config", "--worktree", "core.hooksPath", pinned)

    def setup(self, folder: Path | None = None) -> subprocess.CompletedProcess:
        return self.run(folder or self.main, sys.executable, "-B", str(SCRIPT))

    def commit(self, folder: Path) -> subprocess.CompletedProcess:
        return self.run(folder, "git", "commit", "--allow-empty", "-m", "change")

    def hooks_path(self, folder: Path) -> subprocess.CompletedProcess:
        return self.run(folder, "git", "config", "--get", "core.hooksPath")

    def take_log(self) -> list[str]:
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        self.log.unlink(missing_ok=True)
        return lines


class SetupGitHooksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Repository(Path(temporary.name))

    def assertSetUp(self, result: subprocess.CompletedProcess) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("pre-commit", "pre-push"):
            self.assertIn("agent-watch git hook dispatcher", (self.repo.common / "hooks" / name).read_text())

    def test_each_worktree_runs_the_hooks_of_its_own_branch_after_claude_pinned_them(self):
        repo = self.repo
        repo.pin_like_claude()
        self.assertEqual(repo.commit(repo.worktree).returncode, 0)
        self.assertEqual(repo.take_log(), ["main pre-commit"], "the fixture no longer shows the defect")

        result = repo.setup()

        self.assertSetUp(result)
        self.assertIn("removed core.hooksPath=", result.stdout)
        self.assertIn("from .git/config\n", result.stdout)
        self.assertIn("from .git/worktrees/worktree/config.worktree", result.stdout)
        # Unset, Claude Code writes nothing, and the desktop app clears its pin when it finds hooks
        # in the shared folder. Both read this value when they make a worktree.
        self.assertEqual(repo.hooks_path(repo.main).returncode, 1)
        self.assertEqual(repo.hooks_path(repo.worktree).returncode, 1)

        self.assertEqual(repo.commit(repo.worktree).returncode, 0)
        self.assertEqual(repo.commit(repo.main).returncode, 0)
        self.assertEqual(repo.take_log(), ["other pre-commit", "main pre-commit"])

    def test_setup_run_in_a_linked_worktree_sets_up_the_whole_repository(self):
        repo = self.repo
        repo.pin_like_claude()

        result = repo.setup(repo.worktree)

        self.assertSetUp(result)
        self.assertIn("from .git/config\n", result.stdout)
        self.assertIn("from .git/worktrees/worktree/config.worktree", result.stdout)
        self.assertEqual(repo.hooks_path(repo.main).returncode, 1)
        self.assertEqual(repo.commit(repo.main).returncode, 0)
        self.assertEqual(repo.commit(repo.worktree).returncode, 0)
        self.assertEqual(repo.take_log(), ["main pre-commit", "other pre-commit"])

    def test_pre_push_gets_the_refs_on_stdin_and_the_remote_as_arguments(self):
        repo = self.repo
        self.assertSetUp(repo.setup())

        pushed = repo.run(repo.worktree, "git", "push", "--quiet", "origin", "other")

        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        self.assertEqual(repo.take_log(), ["other pre-push origin refs/heads/other"])

    def test_the_relative_path_of_the_old_setup_is_replaced(self):
        repo = self.repo
        repo.git(repo.main, "config", "core.hooksPath", ".githooks")

        result = repo.setup()

        self.assertSetUp(result)
        self.assertIn("removed core.hooksPath=.githooks from .git/config", result.stdout)
        self.assertEqual(repo.hooks_path(repo.main).returncode, 1)

    def test_a_second_run_changes_nothing(self):
        repo = self.repo
        repo.pin_like_claude()
        self.assertSetUp(repo.setup())
        before = (repo.common / "hooks" / "pre-commit").stat()

        again = repo.setup()

        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout, "task setup: nothing to change\n")
        self.assertEqual((repo.common / "hooks" / "pre-commit").stat().st_mtime_ns, before.st_mtime_ns)

    def test_a_branch_without_hooks_commits_with_no_gate(self):
        repo = self.repo
        repo.git(repo.worktree, "rm", "--quiet", "-r", ".githooks")
        repo.git(repo.worktree, "commit", "--quiet", "--no-verify", "-m", "no hooks")
        self.assertSetUp(repo.setup())

        committed = repo.commit(repo.worktree)

        self.assertEqual(committed.returncode, 0, committed.stderr)
        self.assertIn("has no executable .githooks/pre-commit, so no gate runs", committed.stderr)
        self.assertEqual(repo.take_log(), [])

    def test_a_hook_this_setup_did_not_write_stops_it_before_any_change(self):
        repo = self.repo
        repo.git(repo.main, "config", "core.hooksPath", ".githooks")
        foreign = repo.common / "hooks" / "pre-commit"
        foreign.write_text("#!/bin/sh\nexit 0\n")

        result = repo.setup()

        self.assertEqual(result.returncode, 1)
        self.assertIn(".git/hooks/pre-commit is a hook this setup did not write", result.stderr)
        self.assertEqual(foreign.read_text(), "#!/bin/sh\nexit 0\n")
        self.assertEqual(repo.hooks_path(repo.main).stdout.strip(), ".githooks")
        self.assertFalse((repo.common / "hooks" / "pre-push").exists())

    def test_a_hooks_path_this_setup_did_not_write_stops_it(self):
        repo = self.repo
        repo.git(repo.main, "config", "core.hooksPath", "/opt/hooks")

        result = repo.setup()

        self.assertEqual(result.returncode, 1)
        self.assertIn("core.hooksPath in .git/config is /opt/hooks", result.stderr)
        self.assertEqual(repo.hooks_path(repo.main).stdout.strip(), "/opt/hooks")
        self.assertFalse((repo.common / "hooks" / "pre-commit").exists())

    def test_a_global_hooks_path_stops_it(self):
        repo = self.repo
        repo.git(repo.main, "config", "--global", "core.hooksPath", "/opt/hooks")

        result = repo.setup()

        self.assertEqual(result.returncode, 1)
        self.assertIn("core.hooksPath is set in your global Git config (/opt/hooks)", result.stderr)

    def test_a_worktree_pin_this_setup_did_not_write_stays(self):
        repo = self.repo
        repo.git(repo.main, "config", "extensions.worktreeConfig", "true")
        repo.git(repo.worktree, "config", "--worktree", "core.hooksPath", "/dev/null")

        result = repo.setup()

        self.assertSetUp(result)
        self.assertIn("left core.hooksPath=/dev/null in .git/worktrees/worktree/config.worktree", result.stdout)
        self.assertEqual(repo.hooks_path(repo.worktree).stdout.strip(), "/dev/null")


class GateTests(unittest.TestCase):
    """The repository's own gates, run from a linked worktree with `task` replaced by a recorder."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Repository(Path(temporary.name))
        bin = self.repo.base / "bin"
        bin.mkdir()
        (bin / "task").write_text(FAKE_TASK)
        (bin / "task").chmod(0o755)
        self.repo.env["PATH"] = f"{bin}:{self.repo.env['PATH']}"
        for name in ("pre-commit", "pre-push"):
            (self.repo.worktree / ".githooks" / name).write_text((GATES / name).read_text())
        self.repo.git(self.repo.worktree, "commit", "--quiet", "--no-verify", "-am", "real gates")
        self.assertEqual(self.repo.setup().returncode, 0)

    def test_the_commit_gate_builds_without_the_worktrees_git_variables(self):
        committed = self.repo.commit(self.repo.worktree)

        self.assertEqual(committed.returncode, 0, committed.stderr)
        self.assertEqual(self.repo.take_log(), ["task verify GIT_DIR=unset GIT_INDEX_FILE=unset"])

    def test_the_push_gate_builds_without_the_worktrees_git_variables(self):
        pushed = self.repo.run(self.repo.worktree, "git", "push", "--quiet", "origin", "other")

        self.assertEqual(pushed.returncode, 0, pushed.stderr)
        self.assertEqual(self.repo.take_log(), ["task verify-all GIT_DIR=unset GIT_INDEX_FILE=unset"])


if __name__ == "__main__":
    unittest.main()
