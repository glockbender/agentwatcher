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

start_stage_copy() {
  start_copy
  sleep 2
  # It shows every Claude and Codex process on the machine, the person's own sessions among them.
  $AW ax dismiss $DEMO_PID $NAMES
}

save_state() {
  print "DEMO_PID=$DEMO_PID\nGHOSTTY_PID=$GHOSTTY_PID\nSESSIONS_WID=$SESSIONS_WID\nASKER=${ASKER:-}\nIDS=(${IDS[*]:-})" > $STATE
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

  # A virtual machine gets the copy built outside: one signed with the developer certificate keeps
  # the permission to drive Ghostty that was granted to the copy before it (vm.md).
  if [[ -n ${AW_PREBUILT:-} ]]; then
    [[ -d $DEMO_APP ]] || die "AW_PREBUILT is set, but there is no $DEMO_APP"
  else
    say_step "building the debug copy"
    $REPO/scripts/build-app.sh debug $DEMO_APP > $WORK/build.log 2>&1 || die "build failed: $WORK/build.log"
  fi

  # The hooks of the app's own Claude plugin, pointed at the copy's sender, plus a spinner without
  # the person's words. --setting-sources leaves the plugin out, so they go in through --settings.
  # AW_CLAUDE_HOOKS names a copy of the plugin's list where installing the plugin would spoil a
  # clean machine: the setup clip installs the hooks on camera.
  python3 - $DEMO_SETTINGS $SUPPORT/AgentWatch/AgentWatchSend <<'EOF'
import json, os, pathlib, sys
plugin = pathlib.Path(os.environ.get("AW_CLAUDE_HOOKS") or pathlib.Path.home() / ".claude/skills/agent-watch/hooks/hooks.json")
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
# A desktop notification ("Claude needs your permission") would land inside the stage, and so would
# "How is Claude doing this session?", which a session asked after a few turns (Claude Code 2.1.294).
settings = {"hooks": hooks, "spinnerVerbs": {"mode": "replace", "verbs": ["Working", "Thinking", "Reading"]},
            "spinnerTipsEnabled": False, "preferredNotifChannel": "notifications_disabled",
            "env": {"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1"}}
pathlib.Path(sys.argv[1]).write_text(json.dumps(settings, indent=1))
print(f"· {len(hooks)} hooks")
EOF

  [[ -e $SUPPORT ]] && trash $SUPPORT
  say_step "starting the copy"
  start_stage_copy

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
  # Tabs are found by the title Claude gives them, which carries the session's name. Three sessions
  # starting at once in a virtual machine took longer than 20 s to name all three, measured on
  # Claude Code 2.1.294.
  named=""
  for i in {1..240}; do
    titles=$(osascript -e "tell application \"Ghostty\" to get name of every tab of (first window whose id is \"$SESSIONS_WID\")")
    [[ $titles == *$NAMES[1]* && $titles == *$NAMES[2]* && $titles == *$NAMES[3]* ]] && { named=1; break }
    sleep 0.25
  done
  [[ -n $named ]] || die "the tabs are not named after the sessions yet: $titles"

  # A row gets its name with the first prompt. "Check the task list" ends up waiting for an approval.
  # Each session's id comes from the turn its prompt starts, one prompt at a time: a take waits for
  # one session's events, and another that stops to ask on its own — Opus asked to run a command to
  # read a file — must not stand in for it.
  say_step "opening prompts"
  prompts=('Run `task --list` and tell me in one line how many tasks there are.'
    "List the targets in Package.swift in one line." "Reply with one word: ready.")
  IDS=()
  for i in 2 3 1; do
    started=$(count_events turnStarted)
    say $NAMES[i] $prompts[i]
    wait_events turnStarted $started 30 || die "$NAMES[i] did not start its turn"
    IDS[i]=$(last_id turnStarted)
  done
  ASKER=$IDS[1]
  for i in 2 3; do wait_events turnCompleted 0 120 $IDS[i] || die "$NAMES[i] did not finish its turn"; done
  wait_events userInputRequired 0 120 $ASKER || die "Check the task list did not ask"
  save_state
  say_step "up: copy $DEMO_PID, sessions in Ghostty window $SESSIONS_WID"
  ;;

reset-settings)
  [[ -n $DEMO_PID ]] || die "no stage"
  # An event sent while the copy is down is lost: the end of a turn answered just before the
  # restart was, and its session looked like it was still asking. So the copy restarts only when
  # every session is done.
  for i in {1..3}; do
    for t in {1..960}; do [[ $(last_turn_event $IDS[i]) == turnCompleted ]] && break; sleep 0.25; done
    [[ $(last_turn_event $IDS[i]) == turnCompleted ]] || die "$NAMES[i] still works or asks: answer it, or stage.sh down and up"
  done
  $AW quit $DEMO_PID
  for i in {1..40}; do kill -0 $DEMO_PID 2>/dev/null || break; sleep 0.25; done
  f=$SUPPORT/AgentWatch/settings.json
  [[ ! -e $f ]] || trash $f
  start_stage_copy
  save_state
  # A restarted copy shows a session it has not heard from yet as "no signal", the grey ring the
  # README's lamps call a lost session, until the session's next event: each one takes a short turn.
  for i in {1..3}; do
    answered[i]=$(count_events turnCompleted $IDS[i])
    say $NAMES[i] "Reply with one word: ok."
  done
  for i in {1..3}; do
    wait_events turnCompleted $answered[i] 60 $IDS[i] || die "$NAMES[i] did not answer after the restart"
  done
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
