"""The list of measurements. The real documents are checked by `task lint`."""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("measurements", Path(__file__).with_name("measurements.py"))
measurements = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurements)

# Paths are put together from parts, so `task lint` does not take these made-up ones for real.
DOCS = "docs/"
DOC = DOCS + "a.md"


def collect(files):
    return measurements.collect(files)


class MarkerTests(unittest.TestCase):
    def test_one_program_and_several_versions(self):
        self.assertEqual(
            measurements.parse_doc_marker("Claude Code 2.1.270, 2.1.280"),
            [("Claude Code", "2.1.270"), ("Claude Code", "2.1.280")],
        )

    def test_several_programs(self):
        self.assertEqual(
            measurements.parse_doc_marker("Ghostty 1.3.1, macOS 15.3.1"),
            [("Ghostty", "1.3.1"), ("macOS", "15.3.1")],
        )

    def test_a_program_without_a_version_is_not_recorded(self):
        self.assertEqual(
            measurements.parse_doc_marker("Codex, версия не записана"),
            [("Codex", measurements.NOT_RECORDED)],
        )
        self.assertEqual(measurements.parse_doc_marker("macOS"), [("macOS", measurements.NOT_RECORDED)])

    def test_the_longer_program_name_wins(self):
        self.assertEqual(measurements.parse_doc_marker("Codex Desktop 26.1"), [("Codex Desktop", "26.1")])

    def test_a_desktop_app_and_a_pre_release(self):
        self.assertEqual(
            measurements.parse_doc_marker("Claude.app 2.26454.0, Codex 0.162.0-alpha.2"),
            [("Claude.app", "2.26454.0"), ("Codex", "0.162.0-alpha.2")],
        )

    def test_words_inside_a_marker_are_refused(self):
        self.assertIsNone(measurements.parse_doc_marker("macOS 26.6.2 на машине GitHub"))
        self.assertIsNone(measurements.parse_doc_marker("Xcode 26"))


class DocumentTests(unittest.TestCase):
    def test_a_marked_fact_becomes_a_row_with_its_heading(self):
        rows, problems = collect({DOC: "# A\n\n## Имя сессии\n\nИмя приходит позже. Запись появляется через 2 с (замер: Claude Code 2.1.272). Дальше.\n"})
        self.assertEqual(problems, [])
        self.assertEqual(
            rows,
            [("Claude Code", "2.1.272", "Запись появляется через 2 с.", "[a.md, «Имя сессии»](a.md#имя-сессии)")],
        )

    def test_a_claim_without_a_marker_is_a_problem(self):
        _, problems = collect({DOC: "# A\n\nЗамерено: файл пишется на месте.\n"})
        self.assertEqual(problems, [f"{DOC}:3: says it measured something; add (замер: <program> <version>)"])

    def test_a_marker_in_one_bullet_does_not_cover_the_next(self):
        _, problems = collect({DOC: "# A\n\n- первое (замер: macOS 15.3.1);\n- второе тоже замерено.\n"})
        self.assertEqual(problems, [f"{DOC}:4: says it measured something; add (замер: <program> <version>)"])

    def test_a_malformed_marker_is_a_problem(self):
        _, problems = collect({DOC: "# A\n\nФакт (замер: на этой машине).\n"})
        self.assertEqual(len(problems), 1)
        self.assertIn("(замер: на этой машине)", problems[0])

    def test_a_link_in_the_fact_loses_its_target(self):
        rows, _ = collect({DOCS + "adr/0001-x.md": "# A\n\nКак в [ADR-0002](0002-y.md) (замер: macOS 15.3.1).\n"})
        self.assertEqual(rows[0][2], "Как в ADR-0002.")
        self.assertEqual(rows[0][3], "[0001-x.md](adr/0001-x.md)")

    def test_frozen_documents_and_the_list_itself_are_not_read(self):
        text = "# A\n\nЗамерено (замер: macOS 15.3.1).\n"
        rows, problems = collect({DOCS + "research/x.md": text, measurements.OUTPUT: text})
        self.assertEqual((rows, problems), ([], []))

    def test_a_fenced_block_is_not_prose(self):
        rows, problems = collect({DOC: "# A\n\n```text\nзамер\n```\n"})
        self.assertEqual((rows, problems), ([], []))


class CodeTests(unittest.TestCase):
    def test_a_comment_names_the_program_and_versions(self):
        text = "/// Seen in a real session.\n/// Measured on Claude Code 2.1.270 and 2.1.280: the file\n/// is rewritten in place.\nlet x = 1\n"
        rows, _ = collect({"Sources/A/B.swift": text})
        self.assertEqual([(r[0], r[1]) for r in rows], [("Claude Code", "2.1.270"), ("Claude Code", "2.1.280")])
        self.assertEqual(rows[0][3], "`Sources/A/B.swift`")

    def test_a_count_after_the_version_is_not_a_version(self):
        rows, _ = collect({"Sources/A/B.swift": "// Measured on macOS 15.3.1 and 19 sessions.\n"})
        self.assertEqual([(r[0], r[1]) for r in rows], [("macOS", "15.3.1")])

    def test_a_comment_keeps_the_pre_release_tag(self):
        rows, _ = collect({"Sources/A/B.swift": "// Measured on Codex 0.162.0-alpha.2 and 0.163.0-beta: x.\n"})
        self.assertEqual(
            [(r[0], r[1]) for r in rows], [("Codex", "0.162.0-alpha.2"), ("Codex", "0.163.0-beta")]
        )

    def test_measured_on_something_else_is_prose(self):
        rows, _ = collect({"Sources/A/B.swift": "// Measured on a copy with 19 sessions.\n"})
        self.assertEqual(rows, [])


class TroubleshootingTests(unittest.TestCase):
    def test_checked_on_names_each_program(self):
        text = "# T\n\n## The row stays\n\n**Checked on:** Ghostty 1.3.1, Claude Code 2.1.284. Seen once.\n"
        rows, _ = collect({"TROUBLESHOOTING.md": text})
        self.assertEqual([(r[0], r[1]) for r in rows], [("Ghostty", "1.3.1"), ("Claude Code", "2.1.284")])
        self.assertEqual(rows[0][3], "[TROUBLESHOOTING.md, «The row stays»](../TROUBLESHOOTING.md#the-row-stays)")

    def test_not_recorded_gives_no_row(self):
        rows, problems = collect({"TROUBLESHOOTING.md": "# T\n\n## X\n\n**Checked on:** not recorded.\n"})
        self.assertEqual((rows, problems), ([], []))

    def test_programs_are_found_in_the_first_sentence(self):
        text = "# T\n\n## X\n\n**Checked on:** Claude.app 2.26454.0 with Claude Code 2.1.289. Tested: macOS 26.1.\n"
        rows, _ = collect({"TROUBLESHOOTING.md": text})
        self.assertEqual([(r[0], r[1]) for r in rows], [("Claude.app", "2.26454.0"), ("Claude Code", "2.1.289")])

    def test_a_line_naming_no_program_is_a_problem(self):
        _, problems = collect({"TROUBLESHOOTING.md": "# T\n\n## X\n\n**Checked on:** the owner's laptop.\n"})
        self.assertEqual(len(problems), 1)
        self.assertIn("TROUBLESHOOTING.md:5", problems[0])


class RenderTests(unittest.TestCase):
    def test_newest_version_first_and_unrecorded_last(self):
        text = measurements.render(
            [
                ("Claude Code", measurements.NOT_RECORDED, "c", "w"),
                ("Claude Code", "2.1.9", "a", "w"),
                ("Claude Code", "2.1.272", "b", "w"),
            ]
        )
        table = [line for line in text.split("\n") if line.startswith("| ") and "---" not in line][1:]
        self.assertEqual([line.split(" | ")[0] for line in table], ["| Claude Code 2.1.272", "| Claude Code 2.1.9", f"| Claude Code {measurements.NOT_RECORDED}"])

    def test_a_release_comes_before_its_pre_release(self):
        text = measurements.render([("Codex", "0.162.0-alpha.2", "a", "w"), ("Codex", "0.162.0", "b", "w")])
        self.assertLess(text.index("| Codex 0.162.0 |"), text.index("| Codex 0.162.0-alpha.2 |"))

    def test_a_group_of_programs_names_the_program(self):
        text = measurements.render([("GoLand", "2026.1.4", "f", "w")])
        self.assertIn("| GoLand 2026.1.4 | f | w |", text)


if __name__ == "__main__":
    unittest.main()
