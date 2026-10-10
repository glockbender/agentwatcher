#!/bin/bash

# Packages the app bundle into the files a release is made of: a zip and a disk image, each
# with its checksum.
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

# The check copies 0.3.0 and older make before they replace themselves, made here first: unpack
# the archive and verify the bundle strictly. A framework sealed wrongly inside the bundle passes
# everything else and fails only this — and then no such copy can ever update.
unpacked="$(mktemp -d)"
ditto -x -k "$zip_path" "$unpacked"
codesign --verify --strict "$unpacked/AgentWatch.app"

# The feed Sparkle reads, with the archive's EdDSA signature. Only with the release key: without
# it this is a package to try out, and release.yml refuses to go on. The signature is checked
# against the public key the bundle carries before anything is written — a key that does not
# match would publish an update that no installed copy accepts.
appcast_path="$dist_path/appcast.xml"
rm -f "$appcast_path"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    public_key="$(plutil -extract SUPublicEDKey raw -o - "$app_path/Contents/Info.plist" 2>/dev/null)" || {
        echo "SPARKLE_PRIVATE_KEY is set but Info.plist has no SUPublicEDKey to match it" >&2
        exit 1
    }
    tools="$(./scripts/sparkle-tools.sh)"
    signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - "$zip_path")"
    bare_signature="${signature#*edSignature=\"}"
    swift scripts/eddsa-verify.swift "$public_key" "$zip_path" "${bare_signature%%\"*}" >/dev/null || {
        echo "SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in Info.plist" >&2
        exit 1
    }
    python3 scripts/appcast.py "$version" \
        "https://github.com/glockbender/agentwatcher/releases/download/v$version/AgentWatch-$version.zip" \
        "$signature" > "$appcast_path"
else
    echo "warning: SPARKLE_PRIVATE_KEY is not set, so there is no appcast.xml and copies with" \
        "Sparkle would not see this build" >&2
fi

# The image is for the first install: the app beside a link to Applications, so installing is
# one drag. The update keeps downloading the zip — mounting a volume to replace a bundle buys
# nothing. The staging folder stays in $TMPDIR, which macOS clears by itself.
dmg_path="$dist_path/AgentWatch-$version.dmg"
rm -f "$dmg_path" "$dmg_path.sha256"
dmg_root="$(mktemp -d)"
ditto "$app_path" "$dmg_root/AgentWatch.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -quiet -volname "Agent Watch" -srcfolder "$dmg_root" -format UDZO "$dmg_path"
(cd "$dist_path" && shasum -a 256 "AgentWatch-$version.dmg" > "AgentWatch-$version.dmg.sha256")

# What was actually produced, rather than what was asked for. `codesign --verify` fails the
# script; the Gatekeeper verdict is printed and does not, because an ad-hoc release is
# rejected by design and that is the fact the release notes have to carry.
codesign --verify --strict --verbose=1 "$app_path"
echo "--- Gatekeeper verdict"
spctl --assess --type execute --verbose=4 "$app_path" 2>&1 || true
echo "--- Release artifacts"
echo "$zip_path"
echo "$zip_path.sha256"
echo "$dmg_path"
echo "$dmg_path.sha256"
[[ ! -f "$appcast_path" ]] || echo "$appcast_path"
