#!/bin/zsh
# The widget: a session asks, its row says so, and a click lands in its terminal tab at the
# question. Starts from what stage.sh up leaves: "Check the task list" waits for an approval.
set -e
source ${0:A:h}/../lib.sh
STAGE=(360 98 1040 652)
place_sessions $STAGE
select_tab $NAMES[3]
show_widget
place_widget 1026 158
$AW glide 1250 712
sleep 1
asking=$ASKER
answered=$(count_events turnCompleted $asking)

take_begin hero $STAGE
sleep 2
started=$(count_events turnStarted)
mark long-task; say $NAMES[3] "Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words."
wait_events turnStarted $started 5 || take_abort "the long task did not start"
explaining=$(last_id turnStarted)
explained=$(count_events turnCompleted $explaining)
sleep 4
click find $NAMES[1] click
sleep 0.4; $AW glide 1250 712
sleep 1.8; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
sleep 3.5
take_end

# The next take needs the long answer finished.
wait_events turnCompleted $explained 240 $explaining || say_step "the long answer is still running"
