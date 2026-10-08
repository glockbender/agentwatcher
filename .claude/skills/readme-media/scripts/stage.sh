#!/bin/zsh
# stage.sh up | down | reset-settings | status
#
#   up              build a debug copy, start it beside nothing else, open three Claude sessions
#                   in one Ghostty window and bring them to the opening state: one waiting for an
#                   approval, two done. Run it on an empty desktop.
#   down            end the sessions, quit the copy; its support folder goes to the Trash
#   reset-settings  restart the copy with default settings, for another settings take
#   status          what is running
set -e
source ${0:A:h}/lib.sh

start_copy() {
  open -n --env AGENT_WATCH_SUPPORT_DIR=$SUPPORT $DEMO_APP
  local i
  for i in {1..40}; do DEMO_PID=$(demo_pid); [[ -n $DEMO_PID ]] && $AW bar | grep -q " $DEMO_PID " && break; sleep 0.25; done
  [[ -n $DEMO_PID ]] || die "the demo copy did not start"
  sleep 2
  # It shows every Claude and Codex process on the machine, the person's own sessions among them.
  $AW ax dismiss $DEMO_PID $NAMES
}

save_state() {
  print "DEMO_PID=$DEMO_PID\nGHOSTTY_PID=$GHOSTTY_PID\nSESSIONS_WID=$SESSIONS_WID" > $STATE
}

case $1 in
up)
  [[ -z $SESSIONS_WID ]] || [[ -z $(demo_claude_pids) ]] || die "a stage is up already: stage.sh down first"
  $AW check | grep -q false && die "missing permission: $($AW check | grep false)"
  # A copy left by an attempt that stopped halfway.
  [[ -n $(demo_pid) ]] && { $AW quit $(demo_pid); sleep 2 }
  for pid in $(pgrep -x AgentWatch); do
    die "Agent Watch runs ($(ps -o comm= -p $pid)): quit it, or the menu bar shows two icons"
  done
  others=$($AW onscreen | sort -u | tr '\n' ' ')
  [[ -z $others ]] || die "this desktop is not empty: $others"

  say_step "building the debug copy"
  $REPO/scripts/build-app.sh debug $DEMO_APP > $WORK/build.log 2>&1 || die "build failed: $WORK/build.log"

  # The hooks of the app's own Claude plugin, pointed at the copy's sender, plus a spinner without
  # the person's words. --setting-sources leaves the plugin out, so they go in through --settings.
  python3 - $DEMO_SETTINGS $SUPPORT/AgentWatch/AgentWatchSend <<'EOF'
import json, pathlib, sys
plugin = pathlib.Path.home() / ".claude/skills/agent-watch/hooks/hooks.json"
if not plugin.exists():
    sys.exit(f"no {plugin}: install the Claude hooks from Agent Watch first")
hooks = {}
for event, groups in json.loads(plugin.read_text()).get("hooks", {}).items():
    for group in groups:
        for hook in group.get("hooks", []):
            if "AgentWatchSend" in hook.get("command", ""):
                hooks[event] = [{"hooks": [dict(hook, command=f"'{sys.argv[2]}' --source claude --event {event}")]}]
if not hooks:
    sys.exit(f"no Agent Watch hooks in {plugin}")
# A desktop notification ("Claude needs your permission") would land inside the stage.
settings = {"hooks": hooks, "spinnerVerbs": {"mode": "replace", "verbs": ["Working", "Thinking", "Reading"]},
            "spinnerTipsEnabled": False, "preferredNotifChannel": "notifications_disabled"}
pathlib.Path(sys.argv[1]).write_text(json.dumps(settings, indent=1))
print(f"· {len(hooks)} hooks")
EOF

  [[ -e $SUPPORT ]] && trash $SUPPORT
  say_step "starting the copy"
  start_copy

  # One window, a tab per session. Without the person's own settings (their spinner words, status
  # line, plugins), without MCP servers, and asking before tools even when they run in auto mode.
  # `exec`: when Claude ends, its tab closes, and with the last one the window.
  say_step "opening the sessions"
  claude_line() { print -- " clear && exec claude --setting-sources project,local --strict-mcp-config --settings $DEMO_SETTINGS --permission-mode default --name '$1'" }
  config() { print -- "{initial working directory:\"$MAIN\", initial input:\"$(claude_line $1)\" & return, environment variables:{\"AGENT_WATCH_SUPPORT_DIR=$SUPPORT\", \"IS_DEMO=1\"}, font size:14}" }
  started=$(count_events sessionStarted)
  SESSIONS_WID=$(osascript -e "tell application \"Ghostty\"" \
    -e "set w to new window with configuration $(config $NAMES[1])" \
    -e "new tab in w with configuration $(config $NAMES[2])" \
    -e "new tab in w with configuration $(config $NAMES[3])" \
    -e "return id of w" -e "end tell")
  GHOSTTY_PID=$(pgrep -x ghostty | head -1)
  save_state
  for i in {1..3}; do wait_events sessionStarted $(( started + i - 1 )) 60 || die "session $i did not start"; done
  # Tabs are found by the title Claude gives them, which carries the session's name.
  for i in {1..80}; do
    titles=$(osascript -e "tell application \"Ghostty\" to get name of every tab of (first window whose id is \"$SESSIONS_WID\")")
    [[ $titles == *$NAMES[1]* && $titles == *$NAMES[2]* && $titles == *$NAMES[3]* ]] && break
    sleep 0.25
  done

  # A row gets its name with the first prompt. "Check the task list" ends up waiting for an approval.
  say_step "opening prompts"
  done_before=$(count_events turnCompleted)
  say $NAMES[2] "List the targets in Package.swift in one line."
  say $NAMES[3] "Reply with one word: ready."
  asked=$(count_events userInputRequired)
  say $NAMES[1] 'Run `task --list` and tell me in one line how many tasks there are.'
  wait_events turnCompleted $(( done_before + 1 )) 120 || die "the opening turns did not end"
  wait_events userInputRequired $asked 120 || die "Check the task list did not ask"
  say_step "up: copy $DEMO_PID, sessions in Ghostty window $SESSIONS_WID"
  ;;

reset-settings)
  [[ -n $DEMO_PID ]] || die "no stage"
  $AW quit $DEMO_PID
  for i in {1..40}; do kill -0 $DEMO_PID 2>/dev/null || break; sleep 0.25; done
  trash $SUPPORT/AgentWatch/settings.json
  start_copy
  save_state
  say_step "copy restarted with default settings: $DEMO_PID"
  ;;

down)
  for pid in $(demo_claude_pids); do kill -TERM $pid; done
  [[ -n $DEMO_PID ]] && kill -0 $DEMO_PID 2>/dev/null && $AW quit $DEMO_PID
  sleep 1
  [[ -e $SUPPORT ]] && trash $SUPPORT
  rm -f $STATE
  say_step "down. Recordings and clips stay in $WORK"
  ;;

status)
  print "copy: ${DEMO_PID:-none} $(kill -0 ${DEMO_PID:-0} 2>/dev/null && print running || print gone)"
  print "sessions: $(demo_claude_pids | wc -l | tr -d ' ') Claude processes, Ghostty window ${SESSIONS_WID:-none}"
  ;;

*)
  sed -n '2,10p' $0
  exit 2
  ;;
esac
