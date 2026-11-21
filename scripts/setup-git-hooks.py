#!/usr/bin/env python3
"""Install the repository's Git gates so that every worktree runs the hooks of its own branch.

The hooks live in `.githooks/`, one copy per branch. A small dispatcher in the shared hooks folder
(`<common git dir>/hooks/`) runs the copy in the worktree Git is working in. `core.hooksPath` is
left unset on purpose: Claude Code and the Claude desktop app rewrite it to the main checkout's
absolute path when they create a worktree, and every branch then ran the main checkout's hooks.
AGENTS.md, under Local development, has the details.

Exit status: 0 when the hooks are installed, 1 when something this script did not write is in
the way. It then changes nothing and says what to remove.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile

MARKER = "agent-watch git hook dispatcher"
DISPATCHER = f"""#!/bin/sh
# {MARKER}, installed by `task setup`.
# Git starts a hook at the top of the worktree being committed or pushed from, so this runs that
# worktree's own copy: each branch is checked by the hooks it carries.
hook=".githooks/${{0##*/}}"
if [ ! -x "$hook" ]; then
    echo "${{0##*/}}: $(pwd) has no executable $hook, so no gate runs" >&2
    exit 0
fi
exec "$hook" "$@"
"""


class Refused(Exception):
    pass


def git(*arguments: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *arguments], cwd=cwd, capture_output=True, text=True)


def git_output(*arguments: str, cwd: Path) -> str:
    result = git(*arguments, cwd=cwd)
    if result.returncode != 0:
        raise Refused(f"git {' '.join(arguments)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def config_values(file: Path, cwd: Path) -> list[str]:
    if not file.exists():
        return []
    result = git("config", "--file", str(file), "--get-all", "core.hooksPath", cwd=cwd)
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        raise Refused(f"{file} cannot be read: {result.stderr.strip()}")
    return result.stdout.splitlines()


def worktree_roots(top: Path) -> list[Path]:
    listing = git_output("worktree", "list", "--porcelain", cwd=top)
    return [Path(line[len("worktree ") :]) for line in listing.splitlines() if line.startswith("worktree ")]


def written_by_setup(value: str, roots: list[Path]) -> bool:
    """True for the values an older `task setup` wrote and the ones Claude made of them.

    The old setup wrote `.githooks`; Claude resolves it against the main checkout. A value pointing
    at the `.githooks` of any worktree of this repository is one of those, not somebody's own.
    """
    if not os.path.isabs(value):
        return os.path.normpath(value) == ".githooks"
    return any(os.path.realpath(value) == os.path.realpath(root / ".githooks") for root in roots)


def short(path: Path, common: Path) -> str:
    return ".git/" + str(path.relative_to(common)) if path.is_relative_to(common) else str(path)


def plan(top: Path) -> tuple[Path, list[str], list[tuple[Path, list[str]]], list[str]]:
    """Read everything first and refuse before changing anything."""
    common = Path(git_output("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=top))
    source = top / ".githooks"
    if not source.is_dir():
        raise Refused(f"{source} is missing: run this from a checkout of the repository.")
    names = sorted(entry.name for entry in source.iterdir() if entry.is_file())
    roots = worktree_roots(top)

    for scope in ("--global", "--system"):
        result = git("config", scope, "--get", "core.hooksPath", cwd=top)
        if result.returncode == 0:
            raise Refused(
                f"core.hooksPath is set in your {scope[2:]} Git config ({result.stdout.strip()}). "
                "Git would run the hooks from there and never reach this repository's gates. "
                f"Remove it (git config {scope} --unset core.hooksPath) and run task setup again."
            )

    repository = common / "config"
    foreign = [value for value in config_values(repository, top) if not written_by_setup(value, roots)]
    if foreign:
        raise Refused(
            f"core.hooksPath in .git/config is {foreign[0]}, which this setup did not write. "
            "Remove it (git config --unset-all core.hooksPath) and run task setup again."
        )
    clean = [(repository, config_values(repository, top))]

    notes = []
    for file in [common / "config.worktree", *sorted((common / "worktrees").glob("*/config.worktree"))]:
        values = config_values(file, top)
        if values and all(written_by_setup(value, roots) for value in values):
            clean.append((file, values))
        elif values:
            notes.append(f"left core.hooksPath={values[0]} in {short(file, common)}: this setup did not write it")

    for name in names:
        target = common / "hooks" / name
        if target.is_symlink() or (target.exists() and MARKER not in target.read_text(errors="replace")):
            raise Refused(
                f"{short(target, common)} is a hook this setup did not write. "
                "Move it aside and run task setup again."
            )
    return common, names, [(file, values) for file, values in clean if values], notes


def install(top: Path) -> list[str]:
    common, names, clean, notes = plan(top)
    changes = []
    for file, values in clean:
        git_output("config", "--file", str(file), "--unset-all", "core.hooksPath", cwd=top)
        changes.append(f"removed core.hooksPath={values[0]} from {short(file, common)}")

    hooks = common / "hooks"
    hooks.mkdir(exist_ok=True)
    for name in names:
        target = hooks / name
        if target.exists() and target.read_text() == DISPATCHER and os.access(target, os.X_OK):
            continue
        with tempfile.NamedTemporaryFile("w", dir=hooks, delete=False) as handle:
            handle.write(DISPATCHER)
        os.chmod(handle.name, 0o755)
        os.replace(handle.name, target)
        changes.append(f"installed {short(target, common)}")
    return changes + notes


def main() -> int:
    try:
        top = Path(git_output("rev-parse", "--show-toplevel", cwd=Path.cwd()))
        changes = install(top)
    except Refused as refusal:
        print(f"task setup: {refusal}", file=sys.stderr)
        return 1
    for line in changes or ["nothing to change"]:
        print(f"task setup: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
