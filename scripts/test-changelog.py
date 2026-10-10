"""The changelog reader the release workflow runs. The real file is checked when a tag is pushed."""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("changelog", Path(__file__).with_name("changelog.py"))
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

FILE = """# Changelog

## [Unreleased]

- Not out yet.

## [0.4.0] - 2026-10-12

### Added

- One thing a person notices,
  wrapped onto a second line.

### Fixed

- Another.

## [0.3.0] - 2026-10-08

- Older.
"""


class SectionTests(unittest.TestCase):
    def test_the_section_runs_to_the_next_version_without_its_heading(self):
        body = changelog.section(FILE, "0.4.0")
        self.assertTrue(body.startswith("### Added"))
        self.assertTrue(body.endswith("- Another."))
        self.assertNotIn("Older", body)

    def test_the_last_section_runs_to_the_end_of_the_file(self):
        self.assertEqual(changelog.section(FILE, "0.3.0"), "- Older.")

    def test_a_missing_version_has_no_section(self):
        self.assertIsNone(changelog.section(FILE, "0.5.0"))

    def test_a_version_is_matched_whole_not_as_a_prefix(self):
        self.assertIsNone(changelog.section(FILE.replace("[0.4.0]", "[0.4.0.1]"), "0.4.0"))


class CheckTests(unittest.TestCase):
    def test_a_complete_section_passes(self):
        self.assertEqual(changelog.problems(FILE, "0.4.0"), [])

    def test_a_tag_without_a_section_is_named(self):
        self.assertEqual(changelog.problems(FILE, "0.5.0"), ["CHANGELOG.md has no '## [0.5.0] - YYYY-MM-DD' section"])

    def test_the_heading_needs_the_release_date(self):
        found = changelog.problems(FILE.replace("## [0.4.0] - 2026-10-12", "## [0.4.0]"), "0.4.0")
        self.assertEqual(len(found), 1)
        self.assertIn("YYYY-MM-DD", found[0])

    def test_an_empty_section_is_named(self):
        found = changelog.problems("## [0.4.0] - 2026-10-12\n\n## [0.3.0] - 2026-10-08\n- x\n", "0.4.0")
        self.assertEqual(found, ["'## [0.4.0] - 2026-10-12': the section is empty"])

    def test_wrapping_does_not_hide_a_long_bullet(self):
        long = "- " + " ".join(["word"] * 30) + "\n  " + " ".join(["more"] * 30) + "\n"
        found = changelog.problems(FILE.replace("- Another.\n", long), "0.4.0")
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].startswith("60 words, the limit is 50"))


if __name__ == "__main__":
    unittest.main()
