#!/bin/bash
# Updates a copy of the app end to end in a clean macOS: Sparkle's windows, a real download, a
# real replacement of the bundle — and every way the download can fail before that.
#
#     ./scripts/e2e-update.sh                # this working tree, against a local server
#     ./scripts/e2e-update.sh --from v0.3.0  # that published release, to the latest on GitHub
#
# Runs before every release (the release skill calls it) rather than on every push: it takes a few
# minutes and needs the Tart machine `aw-golden` that the README clips use
# (.claude/skills/readme-media/vm.md says how it was made). Nothing happens on this Mac's screen:
# the windows open and the buttons are pressed inside a throwaway clone of that machine, which is
# deleted at the end with `tart delete` — a machine never goes to the Trash.
#
# What runs there is this working tree, built in debug: an old copy (0.9.0) and a new one (0.9.2),
# both signed ad-hoc like a release, and a local server playing GitHub with feeds that behave well
# or badly. The copies carry a throwaway EdDSA key made for this run, never the release key.
# scripts/update-test/machine.sh lists the cases; out/result.txt has one line per case.
#
# With --from, after a release is published: that earlier release, downloaded as a person would
# have it, finds the new one on GitHub and replaces itself — with its own updater (0.3.0) or with
# Sparkle — exactly as the copies people run will.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$project_root/scripts/update-test"
vm="aw-update"
golden="aw-golden"
port=8123
export PATH="$HOME/.local/bin:$PATH"

command -v tart >/dev/null || { echo "no tart: see .claude/skills/readme-media/vm.md" >&2; exit 1; }
tart get "$golden" >/dev/null 2>&1 || { echo "no $golden machine: see .claude/skills/readme-media/vm.md" >&2; exit 1; }
if tart get "$vm" >/dev/null 2>&1; then
    echo "$vm exists already, left by a run that did not finish: tart delete $vm" >&2
    exit 1
fi

work="$HOME/Library/Caches/agent-watch-update-test/$(date +%Y%m%d-%H%M%S)"
share="$work/share"
mkdir -p "$share/serve/feeds" "$share/old" "$share/new"
say() { printf '\n== %s\n' "$1"; }

# Runs machine.sh with <arguments> in a throwaway clone of the golden machine, prints a line per
# case, and exits: 1 when a case failed, keeping the folder; 0 after moving it to the Trash.
run_in_machine() { # [machine.sh arguments]
    swiftc -O -target arm64-apple-macos14 -o "$share/ax" "$here/ax.swift"
    cp "$here/server.py" "$here/machine.sh" "$share/"
    say "Running in a clone of $golden"
    tart clone "$golden" "$vm"
    trap cleanup EXIT
    nohup tart run --dir="aw:$share" --no-graphics "$vm" >"$work/tart.log" 2>&1 &
    for _ in $(seq 1 90); do in_vm 'pgrep -x Dock' >/dev/null 2>&1 && break; sleep 2; done
    in_vm 'pgrep -x Dock' >/dev/null 2>&1 || { echo "the machine did not start: $work/tart.log" >&2; exit 1; }
    # The desktop needs a moment after the Dock; a window opened before it can land behind.
    sleep 5
    in_vm "zsh '/Volumes/My Shared Files/aw/machine.sh' $*" || true

    say "Result"
    cat "$share/out/result.txt"
    if grep -q ' FAILED' "$share/out/result.txt" || [[ ! -s "$share/out/result.txt" ]]; then
        echo "what each window said and showed is in $share/out" >&2
        exit 1
    fi
    # Kept on failure for inspection; on success it goes to the Trash with the copies in it.
    /usr/bin/trash "$work"
    echo "PASSED; the test folder was moved to the Trash"
    exit 0
}
cleanup() { tart stop "$vm" >/dev/null 2>&1 || true; tart delete "$vm" >/dev/null 2>&1 || true; }
in_vm() { tart exec "$vm" zsh -lc "$1"; }

if [[ "${1:-}" == "--from" ]]; then
    from_tag="${2:?usage: e2e-update.sh --from <tag of a published release>}"
    latest="$(gh release view --repo glockbender/agentwatcher --json tagName --jq .tagName)"
    [[ "$latest" != "$from_tag" ]] || { echo "$from_tag is the latest release: nothing to update to" >&2; exit 1; }
    say "Downloading $from_tag, to update to $latest"
    gh release download "$from_tag" --repo glockbender/agentwatcher --pattern "AgentWatch-${from_tag#v}.zip" --dir "$work"
    ditto -x -k "$work/AgentWatch-${from_tag#v}.zip" "$share/old"
    run_in_machine published "${latest#v}"
fi

AGENT_WATCH_SIGNING_IDENTITY=- "$project_root/scripts/build-app.sh" debug "$work/build/AgentWatch.app" >"$work/build.log" 2>&1 \
    || { echo "build failed: $work/build.log" >&2; exit 1; }
public_key="$(swift "$here/testkey.swift" "$work")"
# Editing Info.plist breaks the bundle's seal, so each copy is signed again — ad-hoc, as a
# release is, so the test meets the same signature check a release does.
make_copy() { # <version> <destination>
    ditto "$work/build/AgentWatch.app" "$2"
    local plist="$2/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$1" "$plist"
    plutil -replace CFBundleVersion -string "$1" "$plist"
    plutil -replace SUPublicEDKey -string "$public_key" "$plist"
    codesign --force --sign - "$2" >/dev/null 2>&1
    codesign --verify --strict "$2"
}
make_copy 0.9.0 "$share/old/AgentWatch.app"
make_copy 0.9.2 "$share/new/AgentWatch.app"

say "Signing the new copy and writing the feeds"
tools="$("$project_root/scripts/sparkle-tools.sh")"
archive="AgentWatch-0.9.2.zip"
ditto -c -k --keepParent "$share/new/AgentWatch.app" "$share/serve/$archive"
signature="$("$tools/sign_update" --ed-key-file "$work/private.key" "$share/serve/$archive")"
# The real length with the signature of another file: the archive arrives whole and is refused.
printf 'not the archive' >"$work/other"
wrong="sparkle:edSignature=\"$("$tools/sign_update" --ed-key-file "$work/private.key" -p "$work/other")\" ${signature#* }"
cat >"$work/CHANGELOG.md" <<'CHANGES'
# Changelog

## [0.9.2] - 2026-10-12

### Added

- PROBE-NEWEST: a line only the offered version has, with `code` in it.

## [0.9.1] - 2026-10-11

### Fixed

- PROBE-SKIPPED: a line from a version the person never installed.

## [0.9.0] - 2026-10-10

- PROBE-INSTALLED: a line the running version already has, never shown.
CHANGES
feed() { # <name> <archive mode> <signature>
    python3 "$project_root/scripts/appcast.py" 0.9.2 "http://127.0.0.1:$port/zip/$2/$archive" "$3" \
        "$work/CHANGELOG.md" >"$share/serve/feeds/$1.xml"
}
feed good ok "$signature"
feed drop drop "$signature"
feed stall stall "$signature"
feed error error "$signature"
feed badsig ok "$wrong"
run_in_machine
