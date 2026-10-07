"""Checks what the documents promise about each other and about the code.

Each check holds one thing that used to drift silently: a link to a heading that was renamed, a
`docs/…` path in a comment after the file moved, two ADRs that took the same number on parallel
branches, a "§7" that pointed elsewhere once a section was inserted above it, an ADR nobody could
tell was replaced, a document that did not say what it holds, and one that grew into several.
What the documents say is not checked here; whether a sentence is still true is for the person
who changes the code it describes.
"""

import os
from pathlib import Path
import re
import subprocess
import sys

LINK = re.compile(r"\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#+)\s+(.*?)\s*#*\s*$", re.M)
FENCE = re.compile(r"^```.*?^```", re.M | re.S)
DOC_PATH = re.compile(r"\bdocs/[\w./-]+\.md\b")
ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9-]+\.md$")
ADR_MENTION = re.compile(r"\bADR-(\d{4})\b")
SECTION_SIGN = re.compile(r"§\s*\d")
STATUS = re.compile(
    r"^\*\*Статус:\*\* (?:принято \d{4}-\d{2}-\d{2}"
    r"|заменено \[ADR-\d{4}\]\(\d{4}-[a-z0-9-]+\.md\)"
    r"|частично заменено \[ADR-\d{4}\]\(\d{4}-[a-z0-9-]+\.md\) — .+)\.$"
)
MAX_LINES = 500
# Snapshots: an archived study or a published article is kept as it was written.
FROZEN = ("docs/research/", "docs/articles/")


def slug(heading: str) -> str:
    """The anchor GitHub gives a heading: lower case, punctuation dropped, spaces as hyphens."""
    text = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return text.replace(" ", "-")


def anchors(text: str) -> set[str]:
    found, seen = set(), {}
    for match in HEADING.finditer(FENCE.sub("", text)):
        base = slug(match.group(2))
        count = seen.get(base, 0)
        seen[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def link_problems(files: dict[str, str]) -> list[str]:
    """Relative links in Markdown point at a file that exists, and at a heading it has."""
    found = []
    for name, text in files.items():
        if not name.endswith(".md"):
            continue
        prose = FENCE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
        for match in LINK.finditer(prose):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            path, _, anchor = target.partition("#")
            resolved = os.path.normpath(os.path.join(os.path.dirname(name), path)) if path else name
            where = f"{name}:{line_of(prose, match.start())}"
            if resolved not in files and not Path(resolved).exists():
                found.append(f"{where}: links to {target}, which does not exist")
            elif anchor and resolved.endswith(".md") and anchor not in anchors(files.get(resolved, "")):
                found.append(f"{where}: links to {target}, which has no such heading")
    return found


def path_problems(files: dict[str, str]) -> list[str]:
    """A `docs/….md` named anywhere — a comment, a script, another document — exists."""
    found = []
    for name, text in files.items():
        for match in DOC_PATH.finditer(text):
            if match.group(0) not in files:
                found.append(f"{name}:{line_of(text, match.start())}: names {match.group(0)}, which does not exist")
    return found


def adr_problems(files: dict[str, str]) -> list[str]:
    """ADR numbers are unique, and every `ADR-NNNN` cited anywhere is one of them."""
    found, numbers = [], {}
    for name in files:
        path = Path(name)
        if path.parent != Path("docs/adr"):
            continue
        match = ADR_FILE.match(path.name)
        if not match:
            found.append(f"{name}: an ADR file is named NNNN-words-with-hyphens.md")
            continue
        if match.group(1) in numbers:
            found.append(f"{name}: ADR-{match.group(1)} is also {numbers[match.group(1)]}")
        numbers.setdefault(match.group(1), name)
    for name, text in files.items():
        for match in ADR_MENTION.finditer(text):
            if match.group(1) not in numbers:
                found.append(f"{name}:{line_of(text, match.start())}: cites ADR-{match.group(1)}, which does not exist")
    return found


def is_living_doc(name: str) -> bool:
    return name.startswith("docs/") and name.endswith(".md") and not name.startswith(FROZEN)


def section_sign_problems(files: dict[str, str]) -> list[str]:
    """A pointer names its heading: "§7" pointed elsewhere the day a section was inserted above."""
    found = []
    for name, text in files.items():
        if name.startswith(FROZEN) or not name.endswith((".md", ".swift", ".kt")):
            continue
        for match in SECTION_SIGN.finditer(text):
            found.append(f"{name}:{line_of(text, match.start())}: points at a section by number; name the heading")
    return found


def status_problems(files: dict[str, str]) -> list[str]:
    """An ADR says on its third line whether it still holds, so nobody follows a replaced one."""
    found = []
    for name, text in files.items():
        if Path(name).parent != Path("docs/adr") or not name.endswith(".md"):
            continue
        lines = text.split("\n")
        if len(lines) < 3 or not STATUS.match(lines[2]):
            found.append(f"{name}:3: the third line is the status: **Статус:** принято YYYY-MM-DD.")
    return found


def opening_problems(files: dict[str, str]) -> list[str]:
    """A document in docs/ says first what it holds and what it leaves out, so nothing has to list it."""
    found = []
    for name, text in files.items():
        if Path(name).parent != Path("docs") or not name.endswith(".md"):
            continue
        paragraphs = [p for p in text.split("\n\n") if p.strip()]
        opening = " ".join(paragraphs[1].split()) if len(paragraphs) > 1 else ""
        if not (opening.startswith("Здесь") and "Чего здесь нет" in opening):
            found.append(f"{name}:3: opens with «Здесь — …» and «Чего здесь нет: …»")
    return found


def length_problems(files: dict[str, str]) -> list[str]:
    """Past this, a document is several subjects, and the next edit lands under the nearest heading."""
    found = []
    for name, text in files.items():
        if is_living_doc(name) and Path(name).parent == Path("docs") and text.count("\n") > MAX_LINES:
            found.append(f"{name}: {text.count(chr(10))} lines; split it by subject (the limit is {MAX_LINES})")
    return found


CHECKS = (
    link_problems,
    path_problems,
    adr_problems,
    section_sign_problems,
    status_problems,
    opening_problems,
    length_problems,
)


def tracked_text_files() -> dict[str, str]:
    names = subprocess.check_output(["git", "ls-files"], text=True).split("\n")
    files = {}
    for name in filter(None, names):
        if not name.endswith((".md", ".swift", ".kt", ".kts", ".py", ".sh", ".yml", ".plist", ".xml")):
            continue
        try:
            files[name] = Path(name).read_text(encoding="utf-8")
        except (FileNotFoundError, UnicodeDecodeError):
            continue
    return files


def main() -> int:
    os.chdir(Path(__file__).resolve().parent.parent)
    files = tracked_text_files()
    found = [problem for check in CHECKS for problem in check(files)]
    for problem in found:
        print(problem, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
