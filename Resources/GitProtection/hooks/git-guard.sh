#!/bin/sh
# Both hosts consume this hook's stdout. An unavailable helper must return a denial.
contents=$(CDPATH= cd -P -- "$(/usr/bin/dirname -- "$0")/../../.." && pwd) || contents=
if [ -n "$contents" ] && [ -x "$contents/MacOS/AgentWatchGit" ]; then
    if answer=$("$contents/MacOS/AgentWatchGit" hook "$@"); then
        if [ "$#" = 1 ] && [ "$1" = "--check" ] && [ "$answer" != "agent-watch-git-hook-ok" ]; then
            echo "Agent Watch Git could not load the native hook. Check the Agent Watch installation." >&2
            exit 1
        fi
        [ -z "$answer" ] || printf '%s\n' "$answer"
        exit 0
    fi
fi
if [ "$#" = 1 ] && [ "$1" = "--check" ]; then
    echo "Agent Watch Git could not load the native hook. Check the Agent Watch installation." >&2
    exit 1
fi
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Agent Watch Git: the native hook could not run. Check the Agent Watch installation."}}'
