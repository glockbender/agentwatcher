#!/bin/bash
# Stable PreToolUse entry point for Claude and Codex. The decision is returned on stdout.
set -u
hooks="$(cd -P -- "$(/usr/bin/dirname -- "$0")" && pwd)"
check=0
case "$#:$*" in
    "1:--check") check=1 ;;
    0:|"2:--host codex"|"2:--host claude") set -- ;;
    *) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Agent Watch Git: unexpected hook configuration."}}'; exit 0 ;;
esac
for python in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$python" ]] || continue
    # The macOS shim opens an installer if the command line tools are missing.
    if [[ "$python" -ef /usr/bin/python3 ]]; then
        developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null)" && [[ -d "$developer_dir" ]] || continue
    fi
    if answer="$("$python" -I -B -S "$hooks/git_guard.py" "$@")"; then
        [[ -z "$answer" ]] || printf '%s\n' "$answer"
        exit 0
    else
        status=$?
    fi
    # Exit 3 comes only from the preflight version check, before reading stdin.
    [[ "$status" == 3 ]] && continue
    # A failed interpreter might already have consumed the input.
    break
done
if [[ "$check" == 1 ]]; then
    echo "Agent Watch Git could not load its hook. Check the Agent Watch installation and install Python 3.9+ or the Apple Command Line Tools." >&2
    exit 1
fi
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Agent Watch Git: the hook could not run. Install Python 3.9+ or the Apple Command Line Tools and check the Agent Watch installation."}}'
