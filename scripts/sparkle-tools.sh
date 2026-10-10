#!/bin/bash
# Prints the folder with Sparkle's command-line tools (`sign_update` above all), downloading the
# release they come in once and keeping it under .build/.
#
# The tools are not in the Swift package — that carries only the framework — so they come from
# Sparkle's own release, of the same version the package pins, and the download is checked against
# the checksum GitHub lists for it. A version bump in Package.swift without one here fails below,
# rather than signing with tools of another release.

set -euo pipefail

version="2.10.0"
checksum="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! grep -qF "exact: \"$version\"" "$project_root/Package.swift"; then
    echo "Package.swift pins another Sparkle than $version: update this script with it" >&2
    exit 1
fi
tools="$project_root/.build/sparkle-tools-$version"
if [[ ! -x "$tools/bin/sign_update" ]]; then
    archive="$(mktemp -d)/Sparkle-$version.tar.xz"
    curl --fail --silent --show-error --location --output "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
    if [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$checksum" ]]; then
        echo "Sparkle-$version.tar.xz does not match its published checksum" >&2
        exit 1
    fi
    mkdir -p "$tools"
    tar -xf "$archive" -C "$tools" bin
fi
echo "$tools/bin"
