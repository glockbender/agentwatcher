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
# Seven, so the list outgrows a widget sized for four and By state has a crowd to sort.
NAMES=("Check the task list" "List the targets" "Explain the architecture" "Review the README" "Find the TODOs"
  "Count the tests" "Sum up the plan")
mkdir -p $WORK
[[ -f $STATE ]] && source $STATE
# The menu bar's height in points: 38 under a notch, 25 on a screen without one, such as a virtual
# machine's. Windows on a stage start right below it.
BAR=$($AW screen | awk '{ print $2 }')

die() { print -u2 -- "$*"; exit 1 }
say_step() { print -- "· $*" }

# discard <path>…: a sandbox file goes — a folder the scripts made only to throw away. Into the
# Trash, unless the owner chose at the skill's start to delete such files at once (AW_DISCARD=delete,
# SKILL.md «До начала»).
discard() {
  local p
  for p in "$@"; do [[ -n $p && $p != / && $p != $HOME ]] || die "discard: refusing '$p'"; done
  if [[ ${AW_DISCARD:-trash} == delete ]]; then rm -rf -- "$@"; else trash "$@"; fi
}

# Under `set -e` a failed command ends a take before its take_end, and a recording left running grows
# by up to 27 MB a second and holds `tart exec` open. Whatever ends the script stops it first; a take
# adds its own clean-up to AT_EXIT.
AT_EXIT=()
at_exit() {
  [[ -z ${REC:-} ]] || take_end failed
  local command
  for command in $AT_EXIT; do eval $command; done
}
trap at_exit EXIT

# MARK: - The demo copy and its sessions

demo_pid() { pgrep -f "^$DEMO_APP/Contents/MacOS/AgentWatch\$" | head -1 }

# Start the copy and wait for its icon. A first start shows the widget's "Connect Agent" at once.
start_copy() {
  open -n --env AGENT_WATCH_SUPPORT_DIR=$SUPPORT $DEMO_APP
  local i
  for i in {1..40}; do DEMO_PID=$(demo_pid); [[ -n $DEMO_PID ]] && $AW bar | grep -q " $DEMO_PID " && break; sleep 0.25; done
  [[ -n $DEMO_PID ]] || die "the demo copy did not start"
}

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
# The stage's sessions that have not ended, by their index in NAMES.
live_sessions() { local i; for i in {1..$#NAMES}; do (( $(count_events sessionEnded $IDS[i]) )) || print $i; done }
last_id() { grep -E " · $1( |\$)" $LOG | tail -1 | awk -F' · ' '{ print $2 }' }
# Where a session's turn stands: turnStarted, userInputRequired or turnCompleted, or nothing yet.
last_turn_event() { # <session id>
  grep -E " · $1 · (turnStarted|userInputRequired|turnCompleted)( |\$)" $LOG | tail -1 | awk -F' · ' '{ split($3, e, " "); print e[1] }'
}

# MARK: - Ghostty, by the id of the demo window

ghostty_tab() { # <AppleScript body using t, the session's terminal> <session> [text]
  local script="on run argv
  tell application \"Ghostty\"
    set w to first window whose id is (item 1 of argv)
    set theTab to first tab of w whose name ends with (item 2 of argv)
    set t to terminal 1 of theTab
    $1
  end tell
end run"
  # A starting session rewrites its tab's title, and for a moment the name is not there: measured on
  # Claude Code 2.1.294 in a virtual machine, right after all three tabs had shown theirs. The tab is
  # looked up again. Only the lookup has failed so far, and it fails before anything is
  # typed; a failure after `input text` would type the text twice.
  local i
  for i in {1..20}; do
    osascript -e "$script" "$SESSIONS_WID" "$2" "${3:-}" 2> /dev/null && return 0
    sleep 0.5
  done
  osascript -e "$script" "$SESSIONS_WID" "$2" "${3:-}"
}
# Paste the text into that session and press Return.
say() { ghostty_tab $'input text (item 3 of argv) to t\n    delay 0.5\n    send key "enter" to t' "$1" "$2" }
press_in() { ghostty_tab "send key (item 3 of argv) to t" "$1" "$2" }
select_tab() { ghostty_tab $'select tab theTab\n    activate window w' "$1" }

# A new Ghostty window, its id printed. With a name, a typed `claude` starts as the stage's sessions
# do and under that name (the shell's `claude` in vm.md); without one, it is the plain `claude`,
# which loads the hooks the guide installed. Either way the copy's sender finds the copy only
# through AGENT_WATCH_SUPPORT_DIR. Ghostty puts the window where its configuration says.
open_terminal() { # [session name]
  local env="\"AGENT_WATCH_SUPPORT_DIR=$SUPPORT\", \"IS_DEMO=1\""
  [[ -z ${1:-} ]] || env+=", \"AW_DEMO_SETTINGS=$DEMO_SETTINGS\", \"AW_SESSION_NAME=$1\""
  osascript -e "tell application \"Ghostty\"" \
    -e "set w to new window with configuration {initial working directory:\"$MAIN\", font size:14, environment variables:{$env}}" \
    -e "activate window w" -e "return id of w" -e "end tell"
}
# Press a key in the window open_terminal opened.
press_in_window() { # <window id> <key>
  osascript -e "tell application \"Ghostty\" to send key \"$2\" to focused terminal of selected tab of (first window whose id is \"$1\")"
}

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

# end_other_sessions: every stage session but "Check the task list" ends. The full-screen dot and
# the menu bar icon show every session the copy counts, each for its share: with the others done or
# quiet the dot was mostly green while one asked. An ended session is not counted.
end_other_sessions() {
  local ended=$(count_events sessionEnded) others=0 i
  for i in {2..$#NAMES}; do
    (( $(count_events sessionEnded $IDS[i]) == 0 )) || continue
    say $NAMES[i] /exit
    others=$(( others + 1 ))
  done
  for i in {1..120}; do (( $(count_events sessionEnded) >= ended + others )) && return 0; sleep 0.25; done
  die "the other sessions did not end"
}

# warm_menu <icon x>: open the menu and close it before the take records. A copy's first menu once
# never showed: the click started the menu, macOS set up its menus for the first time, and nothing
# came. It is a race the takes lost once in several runs (measured on macOS 15.7.7 in the virtual
# machine). Off camera, a second click costs nothing.
warm_menu() {
  local half=$(( $($AW screen | awk '{ print $4 }') / 2 )) item i
  for i in 1 2; do
    glide_click $1 $(( BAR / 2 ))
    for _ in {1..30}; do
      # A closed menu's items sit at the screen's bottom left; an open one hangs from the bar.
      item=($($AW ax find $DEMO_PID "Quit Agent Watch" 2> /dev/null))
      (( ${item[2]:-$half} < half )) && break
      sleep 0.1
    done
    $AW key 53
    sleep 0.5
    (( ${item[2]:-$half} < half )) && return 0
  done
  die "The menu did not open"
}

# MARK: - A take

# take_begin <name> <stage x y w h, in points>: start recording the screen and the marks file.
# Marks are in the recording's own time: T0 is the wall time of its first frame, which the
# recorder writes down as soon as that frame arrives. The cut blurs the menu bar on one's own
# screen; a virtual machine's holds nothing of the person's, and stays sharp.
take_begin() {
  TAKE=$1; shift
  STAGE_RECT=($@)
  MARKS=$WORK/$TAKE.marks
  local screen=($($AW screen))
  [[ $(sysctl -n kern.hv_vmm_present) != 1 ]] || TAKE_BAR=0
  {
    print "stage $*"
    print "scale ${screen[1]}"
    print "bar ${TAKE_BAR:-${screen[2]}}"
  } > $MARKS
  rm -f $WORK/$TAKE.t0
  # Rows of sessions that started since the stage went up, and banners that would land in it. A
  # take that starts the copy itself (setup.sh) has no rows yet.
  [[ -z ${DEMO_PID:-} ]] || $AW ax dismiss $DEMO_PID $NAMES > /dev/null
  $AW clear-notifications > /dev/null
  $AW record $WORK/$TAKE.mov $WORK/$TAKE.t0 < /dev/null 2> $WORK/$TAKE.record.log &
  REC=$!
  local i last="" icon_x frame
  for i in {1..150}; do [[ -s $WORK/$TAKE.t0 ]] && break; sleep 0.02; done
  # TERM: the recorder ignores INT until it is recording, when INT finishes the movie.
  [[ -s $WORK/$TAKE.t0 ]] || { kill -TERM $REC 2>/dev/null; REC=""; die "the recording did not start: $WORK/$TAKE.record.log" }
  T0=$(<$WORK/$TAKE.t0)
  # About 11 s into a recording macOS adds its indicator as a Control Center item at the left end
  # of the status items, and keeps it a while after. On a screen with a notch the leftmost item —
  # often ours — then goes behind it. A stage that holds the menu bar waits for the indicator and
  # stops at once if the icon is gone. Measured on macOS 15.3. Only a notch hides anything, and a
  # menu bar is taller under one (38 points against 25), so elsewhere the take does not wait; a
  # virtual machine shows only a purple dot beside the Control Center icon, and the icon stayed put
  # through a 75 s take, measured on macOS 15.7.7. The wait is bounded all the same, for an
  # indicator that never comes.
  if (( $2 < ${screen[2]} && ${screen[2]} > 30 )) && [[ -n ${DEMO_PID:-} ]]; then
    while (( EPOCHREALTIME - T0 < 15 )); do
      icon_x=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print $1; exit }')
      [[ -n $icon_x ]] || take_abort "the recording indicator pushed the icon behind the notch: make room in the menu bar"
      $AW bar | awk -v x=$icon_x '$4 == "Control" && $1 < x { found = 1 } END { exit !found }' && break
      sleep 0.25
    done
  fi
  # The icon's frame, whenever it changes: what the edit keeps sharp in the blurred menu bar. The
  # first sample is always written, so a take that starts without the icon begins with no frame
  # and nothing sharp.
  {
    local pid=${DEMO_PID:-}
    last="-"
    while :; do
      [[ -n $pid ]] || pid=$(demo_pid)
      frame=""
      [[ -z $pid ]] || frame=$($AW bar | awk -v p=$pid '$3 == p { print $1, $2; exit }')
      [[ $frame != $last ]] && printf "icon %.3f %s\n" $(( EPOCHREALTIME - T0 )) "$frame" >> $MARKS
      last=$frame
      sleep 0.1
    done
  } &
  SAMPLER=$!
  say_step "recording $TAKE"
}

mark() { printf "@ %.3f %s\n" $(( EPOCHREALTIME - T0 )) "$*" >> $MARKS }

# glide_click x y: glide there and click. While a take records, the press goes into its marks as
# "tap <seconds> x y", and the cut draws a ring there: macOS draws none for a posted click.
glide_click() {
  local pressed=$($AW glide $1 $2 click)
  [[ -z ${REC:-} ]] || printf "tap %.3f %s %s\n" $(( pressed - T0 )) $1 $2 >> $MARKS
}

# drag_to x y x2 y2: press at x y, move to x2 y2, release. The press gets a ring, as a click's does.
drag_to() {
  local pressed=$($AW drag $@)
  [[ -z ${REC:-} ]] || printf "tap %.3f %s %s\n" $(( pressed - T0 )) $1 $2 >> $MARKS
}

# open_settings <page>: the settings window on the left of the stage at <page>, the terminal behind
# it on the right and the widget over the terminal in the top right corner. A take after the first
# finds the window open and only moves it again.
open_settings() {
  local top=$(( BAR + 12 )) title r
  place_sessions 330 $top 806 $(( 704 - top ))
  show_widget
  title=$($AW ax windows $DEMO_PID | awk 'NF > 4 { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }')
  if [[ -z $title ]]; then
    $AW ax press $DEMO_PID showWidgetSettings
    sleep 1.5
    title=$($AW ax windows $DEMO_PID | awk 'NF > 4 { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }')
    [[ -n $title ]] || die "the settings window did not open"
  fi
  $AW ax move $DEMO_PID "$title" 16 $top 760 $(( 704 - top ))
  r=($($AW ax find $DEMO_PID $1)); glide_click $r[1] $r[2]
  place_widget 796 $(( BAR + 16 ))
  $AW activate $DEMO_PID
  $AW glide 980 640
}

# click <find|findc> <text> <mark>: glide to the element and click it; the mark carries its frame.
# An element is found before it is on screen: a menu item, while its menu is still opening, has a
# frame at the screen's bottom left, and a click there opened the Dock's Finder. So the click looks
# again, 20 times, until the element is inside the stage: about four seconds in the virtual machine
# while it records, where one search took 0.1 s (measured on macOS 15.7.7).
click() {
  local r parts i
  for i in {1..20}; do
    r=$($AW ax $1 $DEMO_PID "$2" 2> /dev/null) || r=""
    parts=(${=r})
    if [[ -n $r ]] && (( parts[1] >= STAGE_RECT[1] && parts[1] <= STAGE_RECT[1] + STAGE_RECT[3]
      && parts[2] >= STAGE_RECT[2] && parts[2] <= STAGE_RECT[2] + STAGE_RECT[4] )); then
      glide_click $parts[1] $parts[2]
      mark $3 $parts[3,6]
      return 0
    fi
    sleep 0.1
  done
  take_abort "no element on the stage: $2${r:+ (found at $r)}"
}

# take_end [failed]: stop the recording. A failed take says so in its marks, and `vm.sh fetch`
# leaves it in the machine instead of replacing a good recording here.
take_end() {
  [[ -n ${SAMPLER:-} ]] && kill $SAMPLER 2>/dev/null
  kill -INT $REC 2>/dev/null || true
  wait $REC 2>/dev/null || say_step "the recording did not finish cleanly: $WORK/$TAKE.record.log"
  REC=""
  [[ ${1:-} != failed ]] || print "failed" >> $MARKS
  local size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $WORK/$TAKE.mov)
  say_step "$TAKE.mov $size, marks:"
  grep '^@' $MARKS || true
}

take_abort() { take_end failed; die "take $TAKE stopped: $*" }
