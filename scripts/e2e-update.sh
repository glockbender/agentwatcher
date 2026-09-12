#!/bin/bash

# Updates a copy of the app end to end: builds an older version, lets it find a published
# release, presses the buttons a person would press, and checks what ended up on disk.
#
# Everything happens in a throwaway folder, beside the copy you actually use. The app keeps
# all of its state under one directory, and a debug build takes that directory from
# `AGENT_WATCH_SUPPORT_DIR` — so the test copy has its own socket and never argues with yours.
#
#     ./scripts/e2e-update.sh [tag] [starting-version]
#
# One thing to expect: after installing, the app opens the new copy with `open`, which passes
# no environment. That copy therefore looks in the real directory, finds your running Agent
# Watch and exits after asking it to show itself — so your widget may flash on screen once.
# That is also why your own Agent Watch has to be running: with none there, the installed
# copy — a release build, with no override to point elsewhere — would take the real lock and
# run against your real state until this script killed it.

set -euo pipefail

tag="${1:-v0.1.0}"
old_version="${2:-0.0.9}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/agent-watch-e2e.XXXXXX")"
sandbox_name="$(basename "$sandbox")"
support="$sandbox/support"
app="$sandbox/AgentWatch.app"
mkdir -p "$support"

say() { printf '\n== %s\n' "$1"; }
fail() {
    printf '\nFAILED: %s\n' "$1" >&2
    # The files stay for inspection; the process does not — a copy left running with a modal
    # alert on screen is what every retry would add one more of.
    pkill -f "$sandbox_name" 2>/dev/null || true
    printf 'the sandbox is left for inspection: %s\n' "$sandbox" >&2
    exit 1
}

# A button of the app's own alert, pressed by name rather than by position, so the test does
# not care where the window is or what else is on screen.
#
# The process is addressed by its number, never by its name: the person running this test very
# likely has their own Agent Watch running, `process "AgentWatch"` then resolves to whichever
# one System Events picks, and the test quietly looks at the wrong copy's windows.
#
# Every window is tried, not the first: the widget is a window too, and it is already up.
press() {
    local label="$1" seconds="${2:-60}" waited=0
    local target="(first application process whose unix id is $started_pid)"
    # The process is named in full on every line rather than kept in a variable: a reference
    # saved with `set target to …` stops resolving as a container, and `window 1 of target`
    # then finds nothing while the same query written out finds the button. Measured.
    until osascript \
        -e "tell application \"System Events\"" \
        -e "repeat with i from 1 to (count of windows of $target)" \
        -e "try" \
        -e "click button \"$label\" of window i of $target" \
        -e "return \"pressed\"" \
        -e "end try" \
        -e "end repeat" \
        -e "error \"no such button\"" \
        -e "end tell" >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [[ "$waited" -ge "$seconds" ]]; then
            return 1
        fi
    done
    printf '   pressed: %s (after %ss)\n' "$label" "$waited"
}

version_of() {
    plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# Your own copy is matched by executable name and never by path: it may be installed anywhere.
pgrep -x AgentWatch >/dev/null || fail "start your own Agent Watch first — see the header of this script"

say "Building the copy to be updated ($old_version)"
"$project_root/scripts/build-app.sh" debug "$app" >/dev/null
plutil -replace CFBundleShortVersionString -string "$old_version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$old_version" "$app/Contents/Info.plist"
# Editing `Info.plist` breaks the seal on the bundle, so it is signed again. Ad-hoc is enough:
# nothing downloads this copy, so nothing quarantines it.
codesign --force --sign - "$app/Contents/MacOS/AgentWatchSend" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1
printf '   %s is %s\n' "$app" "$(version_of "$app")"

# Started through `open`, not by running the executable: a process launched straight from a
# shell never registers with Launch Services, and System Events then cannot see its windows at
# all — measured, the process list simply does not contain it. `--env` is what makes that
# possible while still pointing the copy at its own state directory.
say "Starting it against $tag"
open --env "AGENT_WATCH_SUPPORT_DIR=$support" \
    --env "AGENT_WATCH_RELEASE_URL=https://api.github.com/repos/glockbender/agentwatcher/releases/tags/$tag" \
    -n "$app"
started_pid=""
for _ in $(seq 1 20); do
    # Matched on the sandbox's own name, not on the path this script holds: `open` starts the
    # process under the canonical path (`/private/var/...`), so the two strings differ.
    # `|| true` because pgrep exits 1 when it finds nothing, and this loop exists precisely to
    # wait for something that is not there yet — `set -e` would end the run on the first turn.
    started_pid="$(pgrep -f "$sandbox_name" | head -1 || true)"
    if [[ -n "$started_pid" ]]; then
        break
    fi
    sleep 1
done
[[ -n "$started_pid" ]] || fail "the copy under test never started"
printf '   pid %s, state in %s\n' "$started_pid" "$support"

say "Answering the dialogs"
press "Download" 60 || fail "no update was offered within a minute"
press "Install and Relaunch" 120 || fail "the download never finished"

say "Waiting for the bundle to change"
installed=""
for _ in $(seq 1 60); do
    installed="$(version_of "$app")"
    if [[ -n "$installed" && "$installed" != "$old_version" ]]; then
        break
    fi
    sleep 1
done
[[ -n "$installed" && "$installed" != "$old_version" ]] || fail "the bundle is still $old_version"
printf '   the bundle on disk is now %s\n' "$installed"

# The copy that was running has to be gone: it replaced itself and asked to be restarted.
for _ in $(seq 1 20); do
    kill -0 "$started_pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$started_pid" 2>/dev/null; then
    fail "the old process is still running"
fi
printf '   the old process exited\n'

# What was installed is a release build, and a release build ignores `AGENT_WATCH_SUPPORT_DIR`
# on purpose — so it cannot be started here without competing for the real socket with the
# copy the person actually uses. What can be checked is that a working app landed on disk.
say "Checking what was installed"
codesign --verify --strict "$app" 2>/dev/null || fail "the installed bundle is not properly signed"
for executable in AgentWatch AgentWatchSend; do
    if [[ ! -x "$app/Contents/MacOS/$executable" ]]; then
        fail "the installed bundle has no $executable"
    fi
done
printf '   signature intact, both executables in place\n'
pkill -f "$sandbox_name" 2>/dev/null || true

say "PASSED: $old_version → $installed"
printf 'the sandbox is left behind, remove it when done: %s\n' "$sandbox"
