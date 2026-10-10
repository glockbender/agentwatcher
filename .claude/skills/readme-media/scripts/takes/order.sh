#!/bin/zsh
# Order: By state turns the list over, By blocks puts a block of rows where it is dragged. The whole
# screen is the frame: the settings window on the left, the terminal behind it on the right, the
# widget over the terminal in the top right corner. Needs default settings: stage.sh reset-settings
# first. Ends one session, whose row the closed block holds for two minutes.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
open_settings Widget
# By blocks moves only what is in another block than the rest: a closed row is. A row of a session
# that ended stays two minutes (WidgetSettings.defaultClosedSessionRetention).
# The last session still open, and never the first three, which the takes after this one use. A
# take again ends the next one: the reset before it restarts the copy, and a restarted copy forgets
# a row that closed before it started.
closing=${${(On)$(live_sessions)}[1]}
(( closing > 3 )) || die "no session left to end: stage.sh down and up"
ended=$(count_events sessionEnded)
say $NAMES[closing] /exit
wait_events sessionEnded $ended 30 || die "$NAMES[closing] did not end"
# The bottom row asks and the two top ones write, so By state turns the list over. Which row is at
# the bottom changes from one stage to the next: rows come in the order the sessions first report.
live=($(live_sessions))
for i in $live; do row_y[i]=$($AW ax find $DEMO_PID "$NAMES[i]" | awk '{ print $2 }'); done
by_height=(${(f)"$(for i in $live; do print $row_y[i] $i; done | sort -n | awk '{ print $2 }')"})
asker=$by_height[-1] writers=($by_height[1,2])
sleep 1

take_begin order $STAGE
sleep 0.8; mark tasks
for i in $writers; do
  say $NAMES[i] "Without using any tools, write a 300-word note on why the app never polls when no session is active."
done
say $NAMES[asker] 'Run `git --version` and tell me the version in one line.'
sleep 4;   click findc "Order," order
sleep 1.6; click findc "By state" state
sleep 3.0; click findc "By blocks" blocks
# The closed block above the active one: its row goes to the top of the widget. The blocks are
# below the window's bottom, so the page scrolls to them first.
sleep 1.2
win=($($AW ax windows $DEMO_PID | awk 'NF > 4 { print $1, $2, $3, $4; exit }'))
$AW glide $(( win[1] + win[3] / 2 )) $(( win[2] + win[4] / 2 ))
$AW scroll 300 0.8; mark scrolled
sleep 0.8
from=($($AW ax findw $DEMO_PID Order Closed))
to=($($AW ax findw $DEMO_PID Order Active))
drag_to $from[1] $from[2] $to[1] $(( to[4] - 3 )); mark drag
sleep 0.6; $AW glide 980 640
sleep 2.4
take_end
# Answer the question it left, or the session waits through the next take.
press_in $NAMES[asker] enter
