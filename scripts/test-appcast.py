"""The update feed the release workflow writes. Sparkle reading a real one is checked in the machine."""

import importlib.util
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("appcast", Path(__file__).with_name("appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = 'sparkle:edSignature="aGVsbG8+/w==" length="4190198"'
URL = "https://github.com/glockbender/agentwatcher/releases/download/v0.4.0/AgentWatch-0.4.0.zip"
CHANGELOG = "# Changelog\n\n## [0.4.0] - 2026-10-12\n\n- Something with `code` & <angle> brackets.\n"


class FeedTests(unittest.TestCase):
    def item(self, changelog: str = CHANGELOG) -> ET.Element:
        return ET.fromstring(appcast.feed("0.4.0", URL, SIGNATURE, changelog, "14.0")).find("channel/item")

    def test_the_entry_names_the_version_the_archive_and_its_signature(self):
        item = self.item()
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "0.4.0")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "0.4.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "14.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), URL)
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "aGVsbG8+/w==")
        self.assertEqual(enclosure.get("length"), "4190198")

    def test_the_description_is_the_whole_changelog_as_markdown(self):
        description = self.item().find("description")
        self.assertEqual(description.get(f"{SPARKLE}format"), "markdown")
        self.assertEqual(description.text, CHANGELOG)

    def test_a_changelog_cannot_end_the_description_early(self):
        tricky = CHANGELOG + "\n- A line that says ]]> in the middle.\n"
        self.assertEqual(self.item(tricky).find("description").text, tricky)

    def test_anything_but_sign_update_output_is_refused(self):
        with self.assertRaises(ValueError):
            appcast.feed("0.4.0", URL, 'sparkle:edSignature="x" length="1" extra="y"', CHANGELOG, "14.0")
        with self.assertRaises(ValueError):
            appcast.feed("0.4.0", URL, "", CHANGELOG, "14.0")


if __name__ == "__main__":
    unittest.main()
