#!/bin/bash

set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug | release) ;;
    *)
        echo "usage: $0 [debug|release] [output .app path]" >&2
        exit 2
        ;;
esac

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The certificate this project signs with when it is in the keychain. A name rather than a
# fingerprint, so the same line works for whoever created their own.
default_signing_identity="Agent Watch Developer"
# `dist/AgentWatch.app` is the bundle a person copies to /Applications, so a build made for
# something else — the end-to-end update builds a debug copy to be thrown away — names its own
# destination rather than overwriting that one.
app_path="${2:-$project_root/dist/AgentWatch.app}"
# The path is removed and rebuilt below, so only something that names a bundle is accepted.
if [[ "$app_path" != *.app ]]; then
    echo "the output path has to name an .app bundle: $app_path" >&2
    exit 2
fi
contents_path="$app_path/Contents"

cd "$project_root"
# The same flag every other build in the gate carries. Without it this was the one build of
# the five that let a warning through — and it is the one whose output a person installs.
swift build --configuration "$configuration" -Xswiftc -warnings-as-errors
bin_path="$(swift build --configuration "$configuration" --show-bin-path)"

if [[ -e "$app_path" ]]; then
    rm -rf -- "$app_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$bin_path/AgentWatch" "$contents_path/MacOS/AgentWatch"
# The hook sender ships beside the app it belongs to. Hook configuration has to name a
# path that stays valid, and the app registers the sender sitting next to itself — which is
# this file in an installed bundle and the build directory's own copy in development.
cp "$bin_path/AgentWatchSend" "$contents_path/MacOS/AgentWatchSend"
cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
# One version in the repository, two keys in the bundle. `CFBundleShortVersionString` is the
# one a person reads and the one a release is named after; `CFBundleVersion` is what macOS
# compares when it decides which of two copies is newer, and a constant there makes every
# build look like the same build. Writing it here keeps the repository with a single source.
version="$(plutil -extract CFBundleShortVersionString raw -o - "$contents_path/Info.plist")"
plutil -replace CFBundleVersion -string "$version" "$contents_path/Info.plist"
plutil -lint "$contents_path/Info.plist" >/dev/null

if command -v codesign >/dev/null 2>&1; then
    # Which identity seals the bundle, and why it is worth a certificate at all.
    #
    # An ad-hoc signature (`-`) makes the designated requirement a hash of this exact
    # binary, and that hash changes on a rebuild with no source change at all. macOS keeps
    # a permission next to the requirement of whoever was granted it, so every rebuild
    # drops every permission this app has ever been given — Accessibility, Automation,
    # Screen Recording — and a feature that needs one cannot even be tried on oneself.
    #
    # A certificate replaces that hash with the certificate's own identity, which a rebuild
    # does not change. Self-signed is enough for that; Developer ID is for handing the app
    # to other people. Measured both ways in `docs/session-focus-research.md`.
    #
    # Looked up without `-v`, and that is the whole of the difference between working and
    # not: `-v` keeps only identities the system *trusts*, and a self-signed root is not
    # trusted until somebody says so in Keychain Access. Trust is about verifying a
    # signature, not about making one — measured: `codesign` signed with this certificate
    # while `find-identity -v` refused to list it. An identity that genuinely cannot sign
    # makes `codesign` fail here, loudly, which is better than quietly going ad-hoc.
    signing_identity="${AGENT_WATCH_SIGNING_IDENTITY:-}"
    if [[ -z "$signing_identity" ]] &&
        security find-identity -p codesigning 2>/dev/null | grep -qF "\"$default_signing_identity\""; then
        signing_identity="$default_signing_identity"
    fi
    if [[ -z "$signing_identity" ]]; then
        signing_identity="-"
        echo "warning: no '$default_signing_identity' certificate; signing ad-hoc," \
            "so macOS permissions will be lost on the next build — see AGENTS.md" >&2
    fi
    # The nested executable is signed before the bundle that seals it.
    codesign --force --sign "$signing_identity" "$contents_path/MacOS/AgentWatchSend" >/dev/null
    codesign --force --sign "$signing_identity" "$app_path" >/dev/null
fi

echo "$app_path"
