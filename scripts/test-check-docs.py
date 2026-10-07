"""The document checks. The real documents are checked by `task lint`."""

import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("check", Path(__file__).with_name("check-docs.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

# Paths are put together from parts, so `task lint` does not take these made-up ones for real.
DOCS = "docs/"
ADR = DOCS + "adr/"

TARGET = """# Модель сессии

## Фаза `idle` и её выход

## Пример

## Пример
"""


class LinkTests(unittest.TestCase):
    def problems(self, text):
        return check.link_problems({DOCS + "a.md": text, DOCS + "session-model.md": TARGET})

    def test_a_link_to_an_existing_heading_passes(self):
        self.assertEqual(self.problems("[x](session-model.md#фаза-idle-и-её-выход)"), [])

    def test_a_repeated_heading_gets_a_numbered_anchor(self):
        self.assertEqual(self.problems("[x](session-model.md#пример-1)"), [])

    def test_a_missing_file_is_named(self):
        self.assertEqual(
            self.problems("text\n[x](nowhere-at-all.md)"),
            [f"{DOCS}a.md:2: links to nowhere-at-all.md, which does not exist"],
        )

    def test_a_missing_heading_is_named(self):
        self.assertEqual(
            self.problems("[x](session-model.md#фаза)"),
            [f"{DOCS}a.md:1: links to session-model.md#фаза, which has no such heading"],
        )

    def test_a_heading_in_the_same_file_is_found(self):
        self.assertEqual(self.problems("# Заголовок\n[x](#заголовок)"), [])

    def test_a_link_inside_a_code_block_is_not_a_link(self):
        self.assertEqual(self.problems("```\n[x](nowhere-at-all.md)\n```"), [])


class PathTests(unittest.TestCase):
    def test_a_comment_naming_a_moved_document_is_named(self):
        files = {"Sources/A.swift": f"// See `{DOCS}architecture.md`.\n// And `{DOCS}gone.md`.", DOCS + "architecture.md": ""}
        self.assertEqual(check.path_problems(files), [f"Sources/A.swift:2: names {DOCS}gone.md, which does not exist"])


class ADRTests(unittest.TestCase):
    def test_two_files_with_one_number_are_named(self):
        files = {ADR + "0008-one.md": "", ADR + "0008-two.md": ""}
        self.assertEqual(check.adr_problems(files), [f"{ADR}0008-two.md: ADR-0008 is also {ADR}0008-one.md"])

    def test_a_citation_of_a_missing_adr_is_named(self):
        files = {ADR + "0001-one.md": "", "Sources/A.swift": "// ADR-0001, ADR-0002"}
        self.assertEqual(check.adr_problems(files), ["Sources/A.swift:1: cites ADR-0002, which does not exist"])

    def test_an_adr_file_without_a_number_is_named(self):
        files = {ADR + "one.md": ""}
        self.assertEqual(check.adr_problems(files), [f"{ADR}one.md: an ADR file is named NNNN-words-with-hyphens.md"])


class SectionSignTests(unittest.TestCase):
    def test_a_section_number_is_named(self):
        files = {"Sources/A.swift": "// See the plan, §7.", DOCS + "a.md": "Section §  12 there."}
        self.assertEqual(
            check.section_sign_problems(files),
            [
                "Sources/A.swift:1: points at a section by number; name the heading",
                f"{DOCS}a.md:1: points at a section by number; name the heading",
            ],
        )

    def test_an_archived_document_keeps_its_numbers(self):
        self.assertEqual(check.section_sign_problems({DOCS + "research/x.md": "§7"}), [])


class StatusTests(unittest.TestCase):
    def problems(self, status):
        return check.status_problems({ADR + "0003-x.md": f"# X\n\n{status}\n\nText."})

    def test_accepted_and_replaced_pass(self):
        self.assertEqual(self.problems("**Статус:** принято 2026-09-15."), [])
        self.assertEqual(self.problems("**Статус:** заменено [ADR-0016](0016-every-setting.md)."), [])
        self.assertEqual(self.problems("**Статус:** частично заменено [ADR-0016](0016-every-setting.md) — что именно."), [])

    def test_a_missing_or_loose_status_is_named(self):
        expected = [f"{ADR}0003-x.md:3: the third line is the status: **Статус:** принято YYYY-MM-DD."]
        self.assertEqual(self.problems("Text."), expected)
        self.assertEqual(self.problems("**Статус:** действует."), expected)


class OpeningTests(unittest.TestCase):
    def test_an_opening_may_wrap_anywhere(self):
        text = "# A\n\nЗдесь — одно. Чего здесь\nнет: другое.\n\nТекст.\n"
        self.assertEqual(check.opening_problems({DOCS + "a.md": text}), [])

    def test_a_document_without_its_scope_is_named(self):
        files = {DOCS + "a.md": "# A\n\nТекст.\n", ADR + "0001-x.md": "# X\n\nТекст.\n"}
        self.assertEqual(check.opening_problems(files), [f"{DOCS}a.md:3: opens with «Здесь — …» and «Чего здесь нет: …»"])


class LengthTests(unittest.TestCase):
    def test_a_long_document_is_named_and_an_archive_is_not(self):
        long = "строка\n" * (check.MAX_LINES + 1)
        files = {DOCS + "a.md": long, DOCS + "research/b.md": long, DOCS + "c.md": "строка\n" * check.MAX_LINES}
        self.assertEqual(
            check.length_problems(files),
            [f"{DOCS}a.md: {check.MAX_LINES + 1} lines; split it by subject (the limit is {check.MAX_LINES})"],
        )


if __name__ == "__main__":
    unittest.main()
