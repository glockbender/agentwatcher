#!/bin/zsh
# The menu alone: a session starts waiting, the icon changes, the menu takes you to it.
set -e
source ${0:A:h}/../lib.sh
STAGE=(600 0 880 738)
place_sessions 600 38 880 700
select_tab $NAMES[2]
hide_widget
icon=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print int($1 + $2 / 2); exit }')
$AW glide 1300 600
sleep 1

take_begin menu $STAGE
sleep 1.5; mark long-task; say $NAMES[3] "Read docs/architecture.md again and explain it in about 600 words."
sleep 2.5
asked=$(count_events userInputRequired)
mark ask; say $NAMES[1] 'Run `task --list` again and tell me in one line how many tasks there are.'
wait_events userInputRequired $asked 60 || take_abort "Check the task list did not ask"
mark waiting
asking=$(last_id userInputRequired)
answered=$(count_events turnCompleted $asking)
sleep 3.5; $AW glide $icon 19 click; mark open-menu
sleep 1.6; click find $NAMES[1] choose
sleep 0.5; $AW glide 1400 700
sleep 2.2; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
sleep 1.5; $AW glide $icon 19 click; mark reopen
sleep 2.8; mark escape; $AW key 53
sleep 0.3; $AW glide 1400 700
sleep 1.2
take_end
show_widget
