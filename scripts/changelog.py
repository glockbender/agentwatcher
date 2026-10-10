"""Reads CHANGELOG.md for a release: checks a version's section and prints it.

    python3 scripts/changelog.py check 0.4.0     # the section exists and every bullet is short
    python3 scripts/changelog.py section 0.4.0   # the section's text, for the release notes

The release workflow runs both: `check` before it builds anything, so a tag without its
section stops there, and `section` when it writes the draft's notes. The app reads the same
file from the update feed and keeps the sections it has not seen (`Changelog.unseen`).

The word limit is for the reader, who is updating, not debugging: past 50 words a bullet is
explaining how something works inside, and that belongs in the code or the docs.
"""

from pathlib import Path
import re
import sys

BULLET_WORDS = 50
HEADING = re.compile(r"^## \[(?P<name>[^\]]+)\](?P<rest>.*)$")
DATE = re.compile(r"^ - \d{4}-\d{2}-\d{2}$")


def section(text: str, version: str) -> str | None:
    """The lines under `## [version] - date`, up to the next `## `, without the heading itself."""
    lines = text.split("\n")
    start = None
    for index, line in enumerate(lines):
        match = HEADING.match(line)
        if start is None:
            if match and match["name"] == version:
                start = index + 1
        elif line.startswith("## "):
            return "\n".join(lines[start:index]).strip()
    return "\n".join(lines[start:]).strip() if start is not None else None


def bullets(body: str) -> list[str]:
    """Whole bullets, their wrapped lines folded in, so wrapping cannot hide words."""
    found: list[str] = []
    for line in body.split("\n"):
        if line.startswith(("- ", "* ")):
            found.append(line[2:].strip())
        elif found and line.startswith("  ") and line.strip():
            found[-1] += " " + line.strip()
    return found


def problems(text: str, version: str) -> list[str]:
    heading = next((line for line in text.split("\n") if (m := HEADING.match(line)) and m["name"] == version), None)
    if heading is None:
        return [f"CHANGELOG.md has no '## [{version}] - YYYY-MM-DD' section"]
    found = []
    if not DATE.match(HEADING.match(heading)["rest"]):
        found.append(f"'{heading}': the heading ends with ' - YYYY-MM-DD', the release date")
    body = section(text, version) or ""
    if not body:
        found.append(f"'{heading}': the section is empty")
    for bullet in bullets(body):
        words = len(bullet.split())
        if words > BULLET_WORDS:
            found.append(f"{words} words, the limit is {BULLET_WORDS}: {bullet[:60]}…")
    return found


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3) or argv[0] not in ("check", "section"):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    command, version = argv[0], argv[1]
    path = Path(argv[2]) if len(argv) == 3 else Path(__file__).resolve().parent.parent / "CHANGELOG.md"
    text = path.read_text(encoding="utf-8")
    if command == "section":
        body = section(text, version)
        if body is None:
            print(f"no section for {version} in {path}", file=sys.stderr)
            return 1
        print(body)
        return 0
    found = problems(text, version)
    for problem in found:
        print(problem, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
