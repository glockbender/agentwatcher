#!/bin/zsh
# The menu alone: a session starts waiting, the icon changes, the menu takes you to it.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
place_sessions 16 $(( BAR + 12 )) 1120 $(( 692 - BAR ))
select_tab $NAMES[2]
hide_widget
icon=$($AW bar | awk -v p=$DEMO_PID '$3 == p { print int($1 + $2 / 2); exit }')
warm_menu $icon
$AW glide 760 560
sleep 1

take_begin menu $STAGE
sleep 1.5; mark long-task; say $NAMES[3] "Read docs/architecture.md again with the Read tool, no commands, and explain it in about 600 words."
sleep 2.5
asked=$(count_events userInputRequired $ASKER)
mark ask; say $NAMES[1] 'Run `task --list` and tell me in one line which task formats the Swift sources.'
wait_events userInputRequired $asked 60 $ASKER || take_abort "Check the task list did not ask"
mark waiting
asking=$ASKER
answered=$(count_events turnCompleted $asking)
sleep 3.5; $AW glide $icon $(( BAR / 2 )) click; mark open-menu
sleep 1.6; click find $NAMES[1] choose
sleep 0.5; $AW glide 800 600
sleep 2.2; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
sleep 1.5; $AW glide $icon $(( BAR / 2 )) click; mark reopen
sleep 2.8; mark escape; $AW key 53
sleep 0.3; $AW glide 800 600
sleep 1.2
take_end
show_widget
