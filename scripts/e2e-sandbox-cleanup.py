#!/usr/bin/env python3
"""Move expired, marked update-test directories to Trash; never touch active runs."""

import os
from pathlib import Path
import re
import subprocess
import time

MARKER = ".agentwatch-e2e-owner"
RETENTION_SECONDS = 7 * 24 * 60 * 60


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def active_app(name):
    # An interrupted shell can leave its test app alive. Errors are not proof of absence.
    return subprocess.run(
        ["pgrep", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode != 1


def cleanup(root=Path("/private/tmp"), now=None):
    now = time.time() if now is None else now
    moved = 0
    for directory in root.glob("agent-watch-e2e.*"):
        marker = directory / MARKER
        try:
            if not re.fullmatch(r"agent-watch-e2e\.[A-Za-z0-9]{6}", directory.name):
                continue
            if directory.is_symlink() or not directory.is_dir():
                continue
            if directory.stat().st_uid != os.getuid() or marker.is_symlink():
                continue
            if not marker.is_file() or marker.stat().st_size > 32:
                continue
            if now - marker.stat().st_mtime < RETENTION_SECONDS:
                continue
            pid_text = marker.read_text().strip()
            if not pid_text.isascii() or not pid_text.isdecimal():
                continue
            pid = int(pid_text)
            if not 1 < pid <= 2**31 - 1:
                continue
            if process_exists(pid) or active_app(directory.name):
                continue
            subprocess.run(["/usr/bin/trash", str(directory)], check=True)
            moved += 1
        except (OSError, UnicodeError, subprocess.SubprocessError) as error:
            print(f"Could not move old update test to Trash: {directory}: {error}")
    return moved


if __name__ == "__main__":
    count = cleanup()
    if count:
        print(f"Moved {count} expired update-test directories to Trash; empty Trash to reclaim space.")
