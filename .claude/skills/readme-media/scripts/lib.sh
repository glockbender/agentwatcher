# Sourced by stage.sh and the takes: where things live, the demo's state, and the moves a take is
# made of. Nothing here runs on its own.
zmodload zsh/datetime

SCRIPTS=${${(%):-%x}:A:h}
AW=$SCRIPTS/aw-media
REPO=$(git -C $SCRIPTS rev-parse --show-toplevel)
# The sessions run in the main checkout, because Claude Code runs hooks only in a folder it trusts,
# and IS_DEMO skips the trust question without saving the answer. Measured on Claude Code 2.1.293.
MAIN=${$(git -C $SCRIPTS rev-parse --path-format=absolute --git-common-dir):h}
WORK=~/Library/Caches/agent-watch-media
# Short on purpose: the demo copy's socket lives here, and a socket path is limited to 104 bytes.
SUPPORT=~/Library/Caches/aw-demo
LOG=$SUPPORT/AgentWatch/event-debug.log
DEMO_APP=$WORK/AgentWatch.app
DEMO_SETTINGS=$WORK/demo-settings.json
STATE=$WORK/stage.env
NAMES=("Check the task list" "List the targets" "Explain the architecture")
mkdir -p $WORK
[[ -f $STATE ]] && source $STATE

die() { print -u2 -- "$*"; exit 1 }
say_step() { print -- "· $*" }

# MARK: - The demo copy and its sessions

demo_pid() { pgrep -f "^$DEMO_APP/Contents/MacOS/AgentWatch\$" | head -1 }

# Exact process name, then the arguments: `pgrep -f` with the path would also match the shell that
# runs this, whose own command line holds the same path.
demo_claude_pids() {
  local pid
  for pid in $(pgrep -x claude); do
    [[ $(ps -o args= -p $pid) == *"--settings $DEMO_SETTINGS"* ]] && print $pid
  done
}

# Events the demo copy logged, as "id_… · event": the way to wait for a session without looking.
# count_events <event> [session id]
count_events() {
  # grep -c prints 0 and fails when nothing matches; a missing log prints nothing.
  local n=$(grep -c -E "${2:-} · $1( |\$)" $LOG 2>/dev/null)
  print ${n:-0}
}
# wait_events <event> <count before> [seconds] [session id]: until one more such event than before.
wait_events() {
  local i
  for i in {1..$(( ${3:-120} * 4 ))}; do
    (( $(count_events $1 ${4:-}) > $2 )) && return 0
    sleep 0.25
  done
  return 1
}
# The session that logged this event last.
last_id() { grep -E " · $1( |\$)" $LOG | tail -1 | awk -F' · ' '{ print $2 }' }

# MARK: - Ghostty, by the id of the demo window

ghostty_tab() { # <AppleScript body using t, the session's terminal> <session> [text]
  osascript - "$SESSIONS_WID" "$2" "${3:-}" <<EOF
on run argv
  tell application "Ghostty"
    set w to first window whose id is (item 1 of argv)
    set theTab to first tab of w whose name ends with (item 2 of argv)
    set t to terminal 1 of theTab
    $1
  end tell
end run
EOF
}
# Paste the text into that session and press Return.
say() { ghostty_tab $'input text (item 3 of argv) to t\n    delay 0.5\n    send key "enter" to t' "$1" "$2" }
press_in() { ghostty_tab "send key (item 3 of argv) to t" "$1" "$2" }
select_tab() { ghostty_tab $'select tab theTab\n    activate window w' "$1" }

# Move the demo's Ghostty window: AX finds it by the title of its selected tab.
place_sessions() { # x y w h
  local title=$(osascript -e "tell application \"Ghostty\" to get name of (first window whose id is \"$SESSIONS_WID\")")
  $AW ax move $GHOSTTY_PID "$title" $@
}
# The widget is the one window without a title; it keeps its size.
place_widget() { # x y
  local f=($($AW ax windows $DEMO_PID | awk 'NF == 4 { print $3, $4; exit }'))
  $AW ax move $DEMO_PID - $1 $2 $f
}
widget_shown() { $AW ax windows $DEMO_PID | awk 'NF == 4 { found = 1 } END { exit !found }' }
show_widget() { widget_shown || { $AW ax press $DEMO_PID toggleWidget; sleep 0.6 } }
hide_widget() { ! widget_shown || { $AW ax press $DEMO_PID toggleWidget; sleep 0.6 } }

# MARK: - A take

# take_begin <name> <stage x y w h, in points>: start recording the screen and the marks file.
# Marks are in the recording's own time: T0 is the wall time of its first frame, taken from
# ffmpeg's progress reports — the smallest (now - out_time) over the first second of them.
take_begin() {
  TAKE=$1; shift
  MARKS=$WORK/$TAKE.marks
  local screen=($($AW screen))
  {
    print "stage $*"
    print "scale ${screen[1]}"
    print "bar ${screen[2]}"
  } > $MARKS
  rm -f $WORK/$TAKE.progress
  # Rows of sessions that started since the stage went up, and banners that would land in it.
  $AW ax dismiss $DEMO_PID $NAMES > /dev/null
  $AW clear-notifications > /dev/null
  ffmpeg -hide_banner -loglevel error -f avfoundation -capture_cursor 1 -capture_mouse_clicks 1 -framerate 30 \
    -pixel_format uyvy422 -i "Capture screen 0:none" -c:v h264_videotoolbox -b:v 40M \
    -progress $WORK/$TAKE.progress -stats_period 0.1 -y $WORK/$TAKE.mov < /dev/null 2> $WORK/$TAKE.ffmpeg.log &
  REC=$!
  T0=0
  local i us best=1e18 seen=0 last="" icon_x frame
  for i in {1..150}; do
    us=$(grep '^out_time_us=' $WORK/$TAKE.progress 2>/dev/null | tail -1 | cut -d= -f2)
    if [[ -n $us && $us != N/A && $us != $last ]] && (( us > 0 )); then
      last=$us
      (( EPOCHREALTIME - us / 1e6 < best )) && best=$(( EPOCHREALTIME - us / 1e6 ))
      (( ++seen >= 10 )) && break
    fi
    sleep 0.02
  done
  (( seen > 0 )) || { kill -INT $REC 2>/dev/null; die "the recording did not start: $WORK/$TAKE.ffmpeg.log" }
  T0=$best
  # About 11 s into a recording macOS adds its indicator as a Control Center item at the left end
  # of the status items, and keeps it a while after. On a screen with a notch the leftmost item —
  # often ours — then goes behind it. A stage that holds the menu bar waits for the indicator and
  # stops at once if the icon is gone. Measured on macOS 15.3.
  if (( $2 < ${screen[2]} )); then
    for i in {1..100}; do
      icon_x=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print $1; exit }')
      [[ -n $icon_x ]] || take_abort "the recording indicator pushed the icon behind the notch: make room in the menu bar"
      $AW bar | awk -v x=$icon_x '$4 == "Control" && $1 < x { found = 1 } END { exit !found }' && break
      sleep 0.25
    done
  fi
  # The icon's frame, whenever it changes: what the edit keeps sharp in the blurred menu bar.
  {
    last=""
    while :; do
      frame=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print $1, $2; exit }')
      [[ $frame != $last ]] && printf "icon %.3f %s\n" $(( EPOCHREALTIME - T0 )) "$frame" >> $MARKS
      last=$frame
      sleep 0.1
    done
  } &
  SAMPLER=$!
  say_step "recording $TAKE"
}

mark() { printf "@ %.3f %s\n" $(( EPOCHREALTIME - T0 )) "$*" >> $MARKS }

# click <find|findc> <text> <mark>: glide to the element and click it; the mark carries its frame.
click() {
  local r
  r=$($AW ax $1 $DEMO_PID "$2") || take_abort "no element: $2"
  local parts=(${=r})
  $AW glide $parts[1] $parts[2] click
  mark $3 $parts[3,6]
}

# Safe under `set -e` from any point of a take: the recording must never outlive the script.
take_end() {
  [[ -n ${SAMPLER:-} ]] && kill $SAMPLER 2>/dev/null
  kill -INT $REC 2>/dev/null || true
  wait $REC 2>/dev/null || true  # ffmpeg ends with 255 after SIGINT
  local size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $WORK/$TAKE.mov)
  say_step "$TAKE.mov $size, marks:"
  grep '^@' $MARKS
}

take_abort() { take_end; die "take $TAKE stopped: $*" }
