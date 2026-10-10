#!/bin/bash
# Checks the latest published release the way installed copies will meet it: both update paths
# find what they look for, and what they find is whole and signed.
#
#   - copies 0.3.0 and older: `AgentWatch-<version>.zip` and its `.sha256` by exact name, the
#     checksum matching, the unpacked bundle passing `codesign --verify --strict`;
#   - copies with Sparkle: `appcast.xml` naming this version and this archive, with the archive's
#     real length and an EdDSA signature that matches the public key in Resources/Info.plist.
#
# Talks to GitHub, so it is part of the push gate (`task verify-all`) and not of `task verify`,
# which must pass with no network.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
fail() { echo "FAILED: $1" >&2; echo "the files are left in $work" >&2; exit 1; }

curl --fail --silent --show-error --user-agent AgentWatch \
    https://api.github.com/repos/glockbender/agentwatcher/releases/latest >"$work/release.json" \
    || fail "GitHub did not answer for the latest release"
asset_url() { # <name> → its download address, or nothing
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(next((a["browser_download_url"] for a in r.get("assets",[]) if a["name"]==sys.argv[2]),""))' \
        "$work/release.json" "$1"
}
tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$work/release.json")"
version="${tag#v}"
echo "latest published release: $tag"

zip="AgentWatch-$version.zip"
zip_url="$(asset_url "$zip")"
sum_url="$(asset_url "$zip.sha256")"
[[ -n "$zip_url" && -n "$sum_url" ]] || fail "$tag lacks $zip or $zip.sha256, which copies 0.3.0 and older look for"
curl --fail --silent --show-error --location --user-agent AgentWatch --output "$work/$zip" "$zip_url"
curl --fail --silent --show-error --location --user-agent AgentWatch --output "$work/$zip.sha256" "$sum_url"
(cd "$work" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "$zip does not match its .sha256"
mkdir "$work/unpacked"
ditto -x -k "$work/$zip" "$work/unpacked"
codesign --verify --strict "$work/unpacked/AgentWatch.app" 2>/dev/null || fail "the unpacked bundle fails codesign --verify --strict"
unpacked_version="$(plutil -extract CFBundleShortVersionString raw -o - "$work/unpacked/AgentWatch.app/Contents/Info.plist")"
[[ "$unpacked_version" == "$version" ]] || fail "the archive holds $unpacked_version, the tag says $version"
echo "the archive is whole, signed and $version: copies 0.3.0 and older can take it"

feed_url="$(asset_url appcast.xml)"
if [[ -z "$feed_url" ]]; then
    echo "no appcast.xml in $tag: copies with Sparkle have nothing to read in this release"
else
    curl --fail --silent --show-error --location --user-agent AgentWatch --output "$work/appcast.xml" "$feed_url"
    read -r feed_version enclosure length signature < <(python3 - "$work/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
s = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item = ET.parse(sys.argv[1]).getroot().find("channel/item")
e = item.find("enclosure")
print(item.findtext(s + "version"), e.get("url"), e.get("length"), e.get(s + "edSignature"))
PY
    )
    [[ "$feed_version" == "$version" ]] || fail "appcast.xml offers $feed_version in release $tag"
    [[ "$enclosure" == "$zip_url" ]] || fail "appcast.xml points at $enclosure, not at this release's $zip"
    [[ "$length" == "$(stat -f %z "$work/$zip")" ]] || fail "appcast.xml gives the archive $length bytes"
    public_key="$(plutil -extract SUPublicEDKey raw -o - "$project_root/Resources/Info.plist" 2>/dev/null)" \
        || fail "Resources/Info.plist has no SUPublicEDKey to check the signature with"
    swift "$project_root/scripts/eddsa-verify.swift" "$public_key" "$work/$zip" "$signature" >/dev/null \
        || fail "the archive's EdDSA signature does not match SUPublicEDKey"
    echo "appcast.xml names $version and this archive, signed with the key in Info.plist: copies with Sparkle can take it"
fi
/usr/bin/trash "$work"
