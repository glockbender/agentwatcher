#!/bin/bash

# Packages the app bundle into the file a release is made of: one zip, one checksum.
#
# Separate from `build-app.sh` because of one difference that matters. That script signs with
# whatever local certificate it finds, and on this machine that is a self-signed root nobody
# else has ever heard of — fine for keeping macOS permissions across rebuilds, meaningless to
# a person downloading the result. A release signs with an identity named on purpose, or
# ad-hoc and says so.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_path="$project_root/dist"
app_path="$dist_path/AgentWatch.app"

cd "$project_root"
version="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"

# Named on purpose or not at all. An unset variable here becomes `-`, an ad-hoc signature,
# rather than falling through to whatever the keychain happens to hold.
signing_identity="${AGENT_WATCH_RELEASE_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    echo "warning: building an ad-hoc signed release. macOS will refuse to open it until the" \
        "person who downloads it removes the quarantine flag by hand — see docs/distribution.md." \
        "Set AGENT_WATCH_RELEASE_IDENTITY to a Developer ID Application certificate to sign it." >&2
fi

AGENT_WATCH_SIGNING_IDENTITY="$signing_identity" ./scripts/build-app.sh release >/dev/null

zip_path="$dist_path/AgentWatch-$version.zip"
rm -f "$zip_path" "$zip_path.sha256"
# `ditto`, not `zip`: it is the one archiver that keeps a bundle's symlinks and extended
# attributes intact, and a signature that survives the round trip is the whole point.
ditto -c -k --keepParent "$app_path" "$zip_path"
(cd "$dist_path" && shasum -a 256 "AgentWatch-$version.zip" > "AgentWatch-$version.zip.sha256")

# What was actually produced, rather than what was asked for. `codesign --verify` fails the
# script; the Gatekeeper verdict is printed and does not, because an ad-hoc release is
# rejected by design and that is the fact the release notes have to carry.
codesign --verify --strict --verbose=1 "$app_path"
echo "--- Gatekeeper verdict"
spctl --assess --type execute --verbose=4 "$app_path" 2>&1 || true
echo "--- Release artifacts"
echo "$zip_path"
echo "$zip_path.sha256"
