#!/bin/zsh
# The menu bar icon and the one session it follows, in a small terminal right below it: blue while
# the session works, orange while it asks, green once it is done. `icon.sh counts` shows the same in
# the Counts style. Runs after fullscreen.sh, which leaves "Check the task list" the only session.
set -e
source ${0:A:h}/../lib.sh
style=${1:-sphere}
take=icon; [[ $style == sphere ]] || take=$style
# A question of its own for each take, so the answer does not refer to the one before.
question='which task redraws the README pictures'; [[ $style == sphere ]] || question='which task sets up the Git hooks'
STAGE=(512 0 640 400)
hide_widget
end_other_sessions
if [[ $style == counts ]]; then
  # Off camera, as a person would: Settings, the Menu Bar page, Counts.
  $AW ax press $DEMO_PID showWidgetSettings
  sleep 1.5
  r=($($AW ax find $DEMO_PID "Menu Bar")); $AW glide $r[1] $r[2] click
  sleep 1
  r=($($AW ax find $DEMO_PID Counts)); $AW glide $r[1] $r[2] click
  sleep 1
  $AW ax close $DEMO_PID "Menu Bar"
fi
top=$(( BAR + 12 ))
place_sessions 528 $top 608 $(( 384 - top ))
select_tab $NAMES[1]
$AW glide 760 330
sleep 1
[[ $(last_turn_event $ASKER) == turnCompleted ]] || die "Check the task list is not done: the icon would change before the take"

take_begin $take $STAGE
sleep 1.2
asked=$(count_events userInputRequired $ASKER)
mark ask; say $NAMES[1] "Run \`task --list\` and tell me in one line $question."
wait_events userInputRequired $asked 60 $ASKER || take_abort "Check the task list did not ask"
mark waiting
answered=$(count_events turnCompleted $ASKER)
sleep 2.6; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $ASKER && mark done || mark done-timeout
sleep 2.6
take_end
