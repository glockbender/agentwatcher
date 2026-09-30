"""The shape check for TROUBLESHOOTING.md. The real document is checked by `task lint`."""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("check", Path(__file__).with_name("check-troubleshooting.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

README = "See [Troubleshooting](TROUBLESHOOTING.md)."
ENTRY = """## Something looks wrong

**Why:** a reason.

**What to do:** a step.

**Checked on:** Claude Code 2.1.284.
"""


class ShapeTests(unittest.TestCase):
    def test_a_complete_entry_passes(self):
        self.assertEqual(check.problems("# Troubleshooting\n\n" + ENTRY, README), [])

    def test_every_missing_field_is_named(self):
        entry = ENTRY.replace("**What to do:** a step.\n", "")
        self.assertEqual(
            check.problems("# T\n\n" + entry, README),
            ["'Something looks wrong': needs exactly one line starting with **What to do:**, has 0"],
        )

    def test_an_empty_field_does_not_count(self):
        entry = ENTRY.replace("**Checked on:** Claude Code 2.1.284.", "**Checked on:**")
        self.assertEqual(
            check.problems("# T\n\n" + entry, README), ["'Something looks wrong': **Checked on:** is empty"]
        )

    def test_a_readme_without_the_link_is_named(self):
        self.assertEqual(
            check.problems("# T\n\n" + ENTRY, "No link here."), ["README.md does not link to TROUBLESHOOTING.md"]
        )

    def test_a_document_without_entries_is_named(self):
        self.assertEqual(
            check.problems("# Troubleshooting\n", README), ["TROUBLESHOOTING.md has no entries (each starts with '## ')"]
        )


if __name__ == "__main__":
    unittest.main()
