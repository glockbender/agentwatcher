"""Safety checks for selection of disposable update-test directories."""

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("e2e-sandbox-cleanup.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.now = 2_000_000

    def directory(self, name="agent-watch-e2e.abc123", age=8 * 86400, pid="12345"):
        directory = self.root / name
        directory.mkdir()
        marker = directory / cleanup.MARKER
        marker.write_text(pid)
        os.utime(marker, (self.now - age, self.now - age))
        return directory

    def test_only_expired_marked_directories_are_sent_to_trash(self):
        expired = self.directory()
        self.directory("agent-watch-e2e.new123", age=60)
        self.directory("agent-watch-e2e.other-name")
        unmarked = self.root / "agent-watch-e2e.old123"
        unmarked.mkdir()
        with patch.object(cleanup, "process_exists", return_value=False), patch.object(
            cleanup, "active_app", return_value=False
        ), patch.object(cleanup.subprocess, "run") as run:
            self.assertEqual(cleanup.cleanup(self.root, self.now), 1)
            run.assert_called_once_with(["/usr/bin/trash", str(expired)], check=True)

    def test_live_shell_or_orphan_app_is_preserved(self):
        self.directory()
        for shell, app in [(True, False), (False, True)]:
            with self.subTest(shell=shell, app=app), patch.object(
                cleanup, "process_exists", return_value=shell
            ), patch.object(cleanup, "active_app", return_value=app), patch.object(cleanup.subprocess, "run") as run:
                self.assertEqual(cleanup.cleanup(self.root, self.now), 0)
                run.assert_not_called()

    def test_symlinks_and_invalid_markers_are_ignored(self):
        target = self.directory("outside")
        (self.root / "agent-watch-e2e.link12").symlink_to(target, target_is_directory=True)
        other = self.root / "agent-watch-e2e.mark12"
        other.mkdir()
        (other / cleanup.MARKER).symlink_to(target / cleanup.MARKER)
        self.directory("agent-watch-e2e.bad123", pid="0")
        self.directory("agent-watch-e2e.bad124", pid="invalid")
        with patch.object(cleanup.subprocess, "run") as run:
            self.assertEqual(cleanup.cleanup(self.root, self.now), 0)
            run.assert_not_called()

    def test_probe_error_is_treated_as_active(self):
        with patch.object(cleanup.subprocess, "run") as run:
            run.return_value.returncode = 2
            self.assertTrue(cleanup.active_app("agent-watch-e2e.abc123"))

    def test_malformed_markers_do_not_prevent_later_cleanup(self):
        self.directory("agent-watch-e2e.bad125", pid="9" * 30)
        malformed = self.directory("agent-watch-e2e.bad126") / cleanup.MARKER
        malformed.write_bytes(b"\xff\xfe")
        os.utime(malformed, (self.now - 8 * 86400,) * 2)
        valid = self.directory("agent-watch-e2e.good12")
        with patch.object(cleanup, "process_exists", return_value=False), patch.object(
            cleanup, "active_app", return_value=False
        ), patch.object(cleanup.subprocess, "run") as run:
            self.assertEqual(cleanup.cleanup(self.root, self.now), 1)
            run.assert_called_once_with(["/usr/bin/trash", str(valid)], check=True)


if __name__ == "__main__":
    unittest.main()
