#!/bin/zsh
# The full-screen dot: with the terminal in a space of its own, the menu bar and its icon are
# hidden, and a dot in the top right corner says that a session works and then that it asks.
# The menu bar, slid down by the pointer, shows the icon, and the dot steps aside meanwhile. It
# ends every other session: only the icon takes come after it.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
# The rows stay off screen: the dot is what is left for someone who keeps the widget hidden.
hide_widget
end_other_sessions
select_tab $NAMES[1]
$AW ax fullscreen $GHOSTTY_PID "$(osascript -e "tell application \"Ghostty\" to get name of (first window whose id is \"$SESSIONS_WID\")")" on
AT_EXIT+=('$AW ax fullscreen $GHOSTTY_PID "$NAMES[1]" off 2> /dev/null')
sleep 3
$AW glide 700 600
sleep 1
[[ $(last_turn_event $ASKER) == turnCompleted ]] || die "Check the task list is not done: the dot would show before the take"

take_begin fullscreen $STAGE
sleep 1.5
asking=$ASKER
asked=$(count_events userInputRequired $asking)
mark ask; say $NAMES[1] 'Run `task --list` and tell me in one line which task builds the app bundle.'
wait_events userInputRequired $asked 60 $asking || take_abort "Check the task list did not ask"
mark waiting
answered=$(count_events turnCompleted $asking)
# Short of the icon: over it, its tooltip opened and stayed a moment after the menu bar had gone.
sleep 3.0; $AW glide 850 0; mark bar
sleep 2.5; $AW glide 950 400; mark back
sleep 3.0; mark approve; press_in $NAMES[1] enter
wait_events turnCompleted $answered 60 $asking && mark done || mark done-timeout
sleep 2.5
take_end
