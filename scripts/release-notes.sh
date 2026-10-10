#!/bin/bash
# Prints the text of a release: what changed, from CHANGELOG.md, then how to install.
#
#     ./scripts/release-notes.sh 0.4.0
#
# release.yml writes the draft with it, and the release skill runs it before the tag so the owner
# reads the text that will go out. The checksums come from dist/, so `task release` runs first.

set -euo pipefail

version="${1:?usage: release-notes.sh <version>}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
changes="$(python3 scripts/changelog.py section "$version")"
checksums="$(cat "dist/AgentWatch-$version.dmg.sha256" "dist/AgentWatch-$version.zip.sha256")"

cat <<NOTES
## What changed

$changes

## Install

1. Download \`AgentWatch-$version.dmg\`, open it and drag Agent Watch to the
   Applications folder beside it.
2. Remove the quarantine flag macOS puts on anything downloaded:

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/AgentWatch.app
\`\`\`

The second step is needed because this build is signed ad-hoc rather than with an
Apple Developer ID certificate, so macOS cannot check who made it. Without the step
it refuses to open the app.

SHA-256, in the format \`shasum -a 256 -c\` reads:

\`\`\`
$checksums
\`\`\`

The \`.zip\` holds the same app, and \`appcast.xml\` tells installed copies about it: an
installed Agent Watch offers this version itself and lists what changed.

Then open Settings → Tooling and install the hooks for whichever agents you use.
Nothing is written to any agent's configuration until you press install there.

## JetBrains IDE plugin

The \`agent-watch-ide-*.zip\` attached here, when one is, is optional: it makes a
click on a row land on the terminal tab a session runs in rather than on the IDE window.
Install it inside the IDE — Settings → Plugins → the gear → Install Plugin from Disk.
The Tooling page in Settings lists every JetBrains IDE it finds and opens that page for
the one you pick, with the file's path already copied.
NOTES
