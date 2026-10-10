"""Writes the update feed Sparkle reads: one entry, for the release being made.

    python3 scripts/appcast.py <version> <archive url> '<sign_update output>' [CHANGELOG.md]

The entry's description is the whole CHANGELOG.md, not this version's section: the feed is
read by every installed copy, and only the copy knows which versions it has not seen
(`Changelog.unseen` cuts it). `<sign_update output>` is what Sparkle's `sign_update` prints for
the archive — its EdDSA signature and length, as attributes ready for the enclosure.

The release workflow attaches the result to the release as `appcast.xml`, and every copy asks
for it at `…/releases/latest/download/appcast.xml` — GitHub sends that address to the latest
published release, so a draft or a pre-release is never offered.
"""

from pathlib import Path
import plistlib
import re
import sys
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent
SIGNATURE = re.compile(r'^sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"$')


def feed(version: str, url: str, signature: str, changelog: str, minimum_system: str) -> str:
    if not SIGNATURE.match(signature.strip()):
        raise ValueError(f"not what sign_update prints for an archive: {signature!r}")
    # Nothing in a changelog may end the CDATA block early.
    description = changelog.replace("]]>", "]]]]><![CDATA[>")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Watch</title>
    <item>
      <title>{escape(version)}</title>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system)}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{description}]]></description>
      <enclosure url={quoteattr(url)} type="application/octet-stream" {signature.strip()} />
    </item>
  </channel>
</rss>
"""


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    version, url, signature = argv[:3]
    changelog = Path(argv[3]) if len(argv) == 4 else ROOT / "CHANGELOG.md"
    with open(ROOT / "Resources/Info.plist", "rb") as plist:
        minimum_system = plistlib.load(plist)["LSMinimumSystemVersion"]
    print(feed(version, url, signature, changelog.read_text(encoding="utf-8"), minimum_system), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
