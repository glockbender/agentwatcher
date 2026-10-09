#!/bin/zsh
# The opening clip: a terminal opens, a new Claude session starts and asks before it runs a
# command; the widget, the icon and the menu all show it, and the menu takes you to the question.
# Starts from what stage.sh up leaves, with default settings (stage.sh reset-settings after the
# settings take), in a machine whose Ghostty opens new windows in place (vm.md). The new session
# stays: run this take after the others.
set -e
source ${0:A:h}/../lib.sh
STAGE=(600 0 1128 720)
NEW_NAME="Count the tasks"
# The stage's own sessions stay off camera, as rows in the widget for company.
place_sessions 0 $BAR 590 600
# Nobody else waits: the stage leaves "Check the task list" asking.
if [[ $(last_turn_event $ASKER) == userInputRequired ]]; then
  answered=$(count_events turnCompleted $ASKER)
  press_in $NAMES[1] enter
  wait_events turnCompleted $answered 90 $ASKER || die "Check the task list did not finish"
fi
show_widget
place_widget 1388 300
icon=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print int($1 + $2 / 2); exit }')
$AW glide 1100 705
sleep 1

take_begin start $STAGE
started=$(count_events sessionStarted)
sleep 1.5; mark open
window=$(open_terminal $NEW_NAME)
sleep 1.6; mark claude; $AW type claude
sleep 0.3; $AW key 36
wait_events sessionStarted $started 30 || take_abort "the new session did not start"
new=$(last_id sessionStarted)
sleep 1.5
asked=$(count_events userInputRequired $new)
mark question; $AW type 'Run `task --list` and tell me how many tasks there are.' 0.05
sleep 0.3; mark ask; $AW key 36
wait_events userInputRequired $asked 60 $new || take_abort "the new session did not ask"
mark waiting
answered=$(count_events turnCompleted $new)
sleep 2.0; $AW glide $icon $(( BAR / 2 )) click; mark open-menu
# The search takes a second or two in a virtual machine; the menu stands open meanwhile.
sleep 0.6; click findm $NEW_NAME choose
sleep 0.5; $AW glide 1100 705
sleep 1.4; mark approve; press_in_window $window enter
wait_events turnCompleted $answered 60 $new && mark done || mark done-timeout
sleep 3
take_end
