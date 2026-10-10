#!/bin/zsh
# The opening clip: a terminal fills the screen and the widget sits in its top right corner. While
# one session gets a long task, the list scrolls through the seven sessions, another waits to run a
# command; its row and the icon say so, the row's card says what it waits for, and a click on the
# row opens its tab at the question. Starts from what stage.sh up leaves: "Check the task list"
# waits for an approval, and the widget is sized for four rows.
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
# Seven sessions in a widget sized for four. Measured here, before anything moves: once a row's card
# is open, a search by the name finds the card's title first, and a row scrolled out of sight still
# has a frame, below the widget's. Rows come in the order the sessions first reported, so the
# waiting row can be anywhere.
w=($($AW ax windows $DEMO_PID | awk 'NF == 4 { print; exit }'))
r=($($AW ax find $DEMO_PID "$NAMES[1]"))
below=$(( r[4] + r[6] - (w[2] + w[4] - 4) ))
need=$(( below > 0 ? (below + 22) / 23 * 23 : 0 ))
# The list goes down and back. A row's card opens half a second after the pointer comes onto the
# row (ThemeTiming.hoverCardDelay), and a row that scrolls away under a pointer that stands still is
# never left: the first row to pass would open its card. So the pointer stays on a "×", which a card
# never opens over (HUDSessionRowView.hoverRect), and no row without one passes under it. Only the
# waiting row has none yet: the long task starts after the scrolling.
for i in {1..$#NAMES}; do row_y[i]=$($AW ax find $DEMO_PID "$NAMES[i]" | awk '{ print $2 }'); done
by_height=(${(f)"$(for i in {1..$#NAMES}; do print $row_y[i] $i; done | sort -n | awk '{ print $2 }')"})
waiting=$by_height[(I)1]
if (( waiting >= 5 )); then slot=1 rows=3
elif (( waiting <= 3 )); then slot=4 rows=3
else slot=1 rows=2
fi
spot=($(( r[3] + r[5] - 15 )) $row_y[by_height[slot]])
asking=$ASKER
answered=$(count_events turnCompleted $asking)

take_begin start $STAGE
sleep 2.0
$AW glide $spot; mark scroll
$AW scroll $(( rows * 23 )) 1.0 back
(( need == 0 )) || $AW scroll $need 0.3
sleep 0.3
started=$(count_events turnStarted)
mark long-task; say $NAMES[3] "Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words."
wait_events turnStarted $started 5 || take_abort "the long task did not start"
explaining=$(last_id turnStarted)
explained=$(count_events turnCompleted $explaining)
sleep 1.2
# Onto the row, and long enough on it for its card to open and be read.
$AW glide $r[1] $(( r[2] - need )); mark hover
sleep 2.4
glide_click $r[1] $(( r[2] - need )); mark click $r[3] $(( r[4] - need )) $r[5] $r[6]
sleep 0.4; $AW glide 600 600
sleep 1.8; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
# The clip holds the answer a while, then fades out (clips.txt).
sleep 4.5
take_end

# The next take needs the long answer finished.
wait_events turnCompleted $explained 240 $explaining || say_step "the long answer is still running"
