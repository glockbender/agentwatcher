"""Checks the shape of TROUBLESHOOTING.md and that README points to it.

It checks shape, not presence: whether an investigation deserved an entry is decided by
whoever made it (AGENTS.md says when). What it can hold is that every entry answers the same
three questions, so a reader never finds a symptom with no cause or no version.
"""

from pathlib import Path
import sys

FIELDS = ("**Why:**", "**What to do:**", "**Checked on:**")
DOCUMENT = "TROUBLESHOOTING.md"


def problems(document: str, readme: str) -> list[str]:
    found = []
    if f"]({DOCUMENT})" not in readme:
        found.append(f"README.md does not link to {DOCUMENT}")

    entries = document.split("\n## ")[1:]
    if not entries:
        found.append(f"{DOCUMENT} has no entries (each starts with '## ')")
    for entry in entries:
        title, _, body = entry.partition("\n")
        lines = body.splitlines()
        for field in FIELDS:
            matching = [line for line in lines if line.startswith(field)]
            if len(matching) != 1:
                found.append(f"'{title}': needs exactly one line starting with {field}, has {len(matching)}")
            elif not matching[0][len(field) :].strip():
                found.append(f"'{title}': {field} is empty")
    return found


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    found = problems(
        (root / DOCUMENT).read_text(encoding="utf-8"),
        (root / "README.md").read_text(encoding="utf-8"),
    )
    for problem in found:
        print(f"{DOCUMENT}: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
