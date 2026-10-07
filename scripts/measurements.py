"""Builds docs/measurements.md from the markers next to each measured fact.

A fact measured against Claude Code, Codex, a JetBrains IDE or macOS carries its version where it
is stated: `(замер: Claude Code 2.1.272)` in a document, `Measured on Claude Code 2.1.272` in a
code comment, and the **Checked on:** line of a TROUBLESHOOTING.md entry. This script collects them
into the list that answers "what has to be re-checked now that this program updated". The list is
generated so that it cannot drift from the text: `--check` fails when it is stale, and when a
document says it measured something without saying on what.
"""

import os
from pathlib import Path
import re
import subprocess
import sys

OUTPUT = "docs/measurements.md"
# Snapshots: an archived study or a published article is kept as it was written.
FROZEN = ("docs/research/", "docs/articles/")
# A plan says what is still to be measured; its «измерены» is a criterion, not a result.
PLANS = ("docs/implementation-plan.md", "docs/release-plan.md")
GROUPS = (
    ("Claude Code", ("Claude Code", "Claude.app")),
    ("Codex", ("Codex Desktop", "Codex", "ChatGPT.app")),
    ("Ghostty", ("Ghostty",)),
    ("JetBrains IDE", ("GoLand", "IntelliJ IDEA", "PyCharm")),
    ("macOS", ("macOS",)),
)
SUBJECTS = tuple(subject for _, subjects in GROUPS for subject in subjects)
NOT_RECORDED = "версия не записана"
# A pre-release keeps its tag: 0.162.0-alpha.2 is not 0.162.0.
VERSION = r"\d+(?:\.\d+)+(?:-[A-Za-z]+(?:\.\d+)*)?"

DOC_MARKER = re.compile(r"\(замер: ([^)]*)\)")
# A statement that something was measured. A plan to measure («замерить») and a negative («не
# замерено») are not, and a result named by a noun («Замер после — …») slips past this: the
# list is as complete as the words the documents use.
CLAIM = re.compile(
    r"(?<![Нн]е )\b(?:[Зз]амерен[оаы]?|[Зз]америл[аи]?|[Ии]змерен[оаы]?|[Ии]змерил[аи]?)\b"
    r"|\b[Зз]амеры? показал[аи]?\b"
)
CODE_MARKER = re.compile(
    r"[Mm]easured on (" + "|".join(re.escape(s) for s in SUBJECTS) + r")\b"
    r"((?: \d+(?:\.\d+)*)?(?:(?:, | and |, and )" + VERSION + r")*)"
)
CHECKED_ON = re.compile(r"^\*\*Checked on:\*\* (.+)$")
SUBJECT_AND_VERSION = re.compile("(" + "|".join(re.escape(s) for s in SUBJECTS) + ") (" + VERSION + ")")
HEADING = re.compile(r"^(#+)\s+(.*?)\s*#*\s*$")
UNIT_START = re.compile(r"^(?:\||[-*] |\d+\. )")
CODE_COMMENT = {".swift": "//", ".kt": "//", ".kts": "//", ".sh": "#"}
LONGEST_FACT = 240


def slug(heading: str) -> str:
    """The anchor GitHub gives a heading: lower case, punctuation dropped, spaces as hyphens."""
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def parse_doc_marker(body: str) -> list[tuple[str, str]] | None:
    """`Claude Code 2.1.270, 2.1.280, macOS 15.3.1` → one (subject, version) per version named."""
    found, subject = [], None
    for part in (p.strip() for p in body.split(",")):
        named = next((s for s in SUBJECTS if part == s or part.startswith(s + " ")), None)
        if named:
            if subject and not any(s == subject for s, _ in found):
                found.append((subject, NOT_RECORDED))
            subject, rest = named, part[len(named):].strip()
            if rest:
                if not re.fullmatch(VERSION + r"|\d+", rest):
                    return None
                found.append((subject, rest))
        elif subject and (re.fullmatch(VERSION, part) or part == NOT_RECORDED):
            found.append((subject, part))
        else:
            return None
    if subject and not any(s == subject for s, _ in found):
        found.append((subject, NOT_RECORDED))
    return found or None


def parse_code_marker(match: re.Match) -> list[tuple[str, str]]:
    versions = re.findall(r"\d+(?:\.\d+)*", match.group(2))
    return [(match.group(1), v) for v in versions] or [(match.group(1), NOT_RECORDED)]


def units(text: str):
    """(heading, anchor, unit text, first line) for each paragraph, list item or table row.

    A list item and a table row are units of their own, so a marker in one bullet does not
    vouch for a claim in the next.
    """
    heading, anchor, buffer, start, fence, seen = "", "", [], 0, False, {}
    for number, line in enumerate(text.split("\n"), 1):
        if line.startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        match = HEADING.match(line)
        if match or not line.strip() or UNIT_START.match(line):
            if buffer:
                yield heading, anchor, " ".join(buffer), start
                buffer = []
            if match:
                heading = match.group(2)
                base = slug(heading)
                count = seen.get(base, 0)
                seen[base] = count + 1
                anchor = base if count == 0 else f"{base}-{count}"
                if len(match.group(1)) == 1:
                    # The title names the whole file; a fact under it is placed by the file alone.
                    heading = anchor = ""
                continue
            if not line.strip():
                continue
        if not buffer:
            start = number
        buffer.append(line.strip())
    if buffer:
        yield heading, anchor, " ".join(buffer), start


def comment_units(text: str, prefix: str):
    """(comment paragraph, first line) for each run of comment lines, split at blank ones."""
    buffer, start = [], 0
    for number, line in enumerate(text.split("\n") + [""], 1):
        stripped = line.strip()
        body = None
        if stripped.startswith(prefix) and not stripped.startswith("#!"):
            body = stripped.lstrip("/#").strip()
        if body:
            if not buffer:
                start = number
            buffer.append(body)
        elif buffer:
            yield " ".join(buffer), start
            buffer = []


def sentence_around(text: str, start: int, end: int) -> str:
    """The sentence holding text[start:end], without its marker, short enough for a table cell."""
    if text.startswith("|"):
        cells = text.strip("|").split("|")
        offset = 1
        for cell in cells:
            if offset <= start < offset + len(cell) + 1:
                text, start, end = cell, start - offset, end - offset
                break
            offset += len(cell) + 1
    left = max(text.rfind(s, 0, start) for s in (". ", "! ", "? "))
    right = min((i for i in (text.find(s, end) for s in (". ", "! ", "? ")) if i >= 0), default=len(text))
    sentence = text[left + 2 if left >= 0 else 0 : right + 1].strip()
    sentence = DOC_MARKER.sub("", sentence)
    # A link is relative to the file it came from, which is rarely this one.
    sentence = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", sentence)
    sentence = re.sub(r"\s+([.,;:])", r"\1", re.sub(r"\s{2,}", " ", sentence)).strip()
    sentence = sentence.replace("|", "\\|")
    if len(sentence) > LONGEST_FACT:
        sentence = sentence[: LONGEST_FACT - 1].rsplit(" ", 1)[0] + "…"
    return sentence


def is_living_doc(name: str) -> bool:
    return name.startswith("docs/") and name.endswith(".md") and not name.startswith(FROZEN) and name != OUTPUT


def collect(files: dict[str, str]):
    """Every (subject, version, fact, where) the markers name, and every marker problem."""
    rows, problems = [], []
    for name, text in sorted(files.items()):
        suffix = Path(name).suffix
        if is_living_doc(name):
            link = os.path.relpath(name, os.path.dirname(OUTPUT))
            for heading, anchor, unit, line in units(text):
                markers = list(DOC_MARKER.finditer(unit))
                if CLAIM.search(DOC_MARKER.sub("", unit)) and not markers and name not in PLANS:
                    problems.append(f"{name}:{line}: says it measured something; add (замер: <program> <version>)")
                for match in markers:
                    parsed = parse_doc_marker(match.group(1))
                    if parsed is None:
                        problems.append(
                            f"{name}:{line}: {match.group(0)} names one of {', '.join(SUBJECTS)} and versions"
                        )
                        continue
                    where = f"[{Path(name).name}, «{heading}»]({link}#{anchor})" if anchor else f"[{Path(name).name}]({link})"
                    fact = sentence_around(unit, match.start(), match.end())
                    rows += [(subject, version, fact, where) for subject, version in parsed]
        elif name == "TROUBLESHOOTING.md":
            for heading, anchor, unit, line in units(text):
                checked = CHECKED_ON.match(unit)
                if not checked:
                    continue
                # Plain English for the reader, so the programs are found in the first sentence
                # rather than parsed from a marker; one that names none is a problem, not a skip.
                first = re.split(r"\. |; ", checked.group(1).rstrip("."))[0]
                found = SUBJECT_AND_VERSION.findall(first)
                if not found and not first.startswith("not recorded"):
                    problems.append(f"{name}:{line}: **Checked on:** names a program and its version, or says not recorded")
                for subject, version in found:
                    where = f"[TROUBLESHOOTING.md, «{heading}»](../TROUBLESHOOTING.md#{anchor})"
                    rows.append((subject, version, heading.replace("|", "\\|"), where))
        elif suffix in CODE_COMMENT:
            for unit, _ in comment_units(text, CODE_COMMENT[suffix]):
                for match in CODE_MARKER.finditer(unit):
                    fact = sentence_around(unit, match.start(), match.end())
                    rows += [(subject, version, fact, f"`{name}`") for subject, version in parse_code_marker(match)]
    return rows, problems


def version_key(version: str):
    """Newest first; an unrecorded version last, because it cannot be tied to any update."""
    if version == NOT_RECORDED:
        return (1, (), 0)
    release, _, tag = version.partition("-")
    return (0, tuple(-int(part) for part in release.split(".")), 1 if tag else 0)


def render(rows) -> str:
    out = [
        "# Журнал замеров",
        "",
        "Здесь — какие факты о Claude Code, Codex, Ghostty, IDE JetBrains и macOS замерены и на какой",
        "версии: что перепроверить, когда программа обновится. Чего здесь нет: рассуждений вокруг замера —",
        "они в документе или комментарии по ссылке.",
        "",
        "Файл собирает `task measurements` из пометок у самих фактов: `(замер: Claude Code 2.1.272)` в",
        "документах, `Measured on Claude Code 2.1.272` в комментариях кода и строки **Checked on:** в",
        "`TROUBLESHOOTING.md`. Руками его не правят: `task lint` падает, если он отстал от пометок или если",
        "документ говорит «замерено» без пометки.",
        "",
        "Приложение стоит на недокументированных внутренностях этих программ. Они меняются молча, а всё",
        "чтение сделано fail-open — сбой чтения не останавливает агента и не показывается ошибкой, — поэтому",
        "сломавшийся замер выглядит не как ошибка, а как сессия, у которой вдруг нет имени, или как строка,",
        "которая не появилась. Замер с пометкой «версия не записана» нельзя привязать к обновлению:",
        "проверять его придётся целиком.",
    ]
    for title, subjects in GROUPS:
        group = [row for row in rows if row[0] in subjects]
        if not group:
            continue
        group.sort(key=lambda row: (subjects.index(row[0]), version_key(row[1]), row[3], row[2]))
        several = len(subjects) > 1
        out += ["", f"## {title}", "", "| Версия | Что замерено | Где |", "| --- | --- | --- |"]
        for subject, version, fact, where in group:
            label = f"{subject} {version}" if several else version
            out.append(f"| {label} | {fact} | {where} |")
    return "\n".join(out) + "\n"


def tracked_text_files() -> dict[str, str]:
    names = subprocess.check_output(["git", "ls-files"], text=True).split("\n")
    files = {}
    for name in filter(None, names):
        if not (name.endswith(".md") or Path(name).suffix in CODE_COMMENT):
            continue
        try:
            files[name] = Path(name).read_text(encoding="utf-8")
        except (FileNotFoundError, UnicodeDecodeError):
            continue
    return files


def main(argv: list[str]) -> int:
    os.chdir(Path(__file__).resolve().parent.parent)
    rows, problems = collect(tracked_text_files())
    for problem in problems:
        print(problem, file=sys.stderr)
    text = render(rows)
    if "--check" in argv:
        if Path(OUTPUT).read_text(encoding="utf-8") != text:
            print(f"{OUTPUT} is stale; run `task measurements`", file=sys.stderr)
            return 1
    else:
        Path(OUTPUT).write_text(text, encoding="utf-8")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
