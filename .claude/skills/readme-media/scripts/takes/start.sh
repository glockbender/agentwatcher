#!/bin/zsh
# The opening clip: a terminal fills the screen and the widget sits in its top right corner. While
# one session gets a long task, another waits to run a command; its row and the icon say so, the
# row's card says what it waits for, and a click on the row opens its tab at the question. Starts
# from what stage.sh up leaves: "Check the task list" waits for an approval.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
top=$(( BAR + 12 ))
place_sessions 16 $top 1120 $(( 704 - top ))
select_tab $NAMES[3]
show_widget
place_widget 796 $(( BAR + 16 ))
$AW glide 600 600
sleep 1
[[ $(last_turn_event $ASKER) == userInputRequired ]] || die "Check the task list does not wait: stage.sh up leaves it asking"
asking=$ASKER
answered=$(count_events turnCompleted $asking)

take_begin start $STAGE
sleep 1.5
started=$(count_events turnStarted)
mark long-task; say $NAMES[3] "Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words."
wait_events turnStarted $started 5 || take_abort "the long task did not start"
explaining=$(last_id turnStarted)
explained=$(count_events turnCompleted $explaining)
sleep 2.5
# Onto the row, and long enough on it for its card to open and be read.
r=($($AW ax find $DEMO_PID "$NAMES[1]"))
$AW glide $r[1] $r[2]; mark hover
sleep 2.4
click find $NAMES[1] click
sleep 0.4; $AW glide 600 600
sleep 1.8; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
sleep 3
take_end

# The next take needs the long answer finished.
wait_events turnCompleted $explained 240 $explaining || say_step "the long answer is still running"
