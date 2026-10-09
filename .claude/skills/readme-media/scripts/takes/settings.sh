#!/bin/zsh
# Settings: each change shows on the widget at once. The whole screen is the frame: the settings
# window on the left, a terminal behind it on the right, and the widget over the terminal in the
# top right corner. Needs default settings — after a settings take, run stage.sh reset-settings
# before the next one.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
top=$(( BAR + 12 ))
place_sessions 330 $top 806 $(( 704 - top ))
show_widget
$AW ax press $DEMO_PID showWidgetSettings
sleep 1.5
title=$($AW ax windows $DEMO_PID | awk 'NF > 4 { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }')
[[ -n $title ]] || die "the settings window did not open"
$AW ax move $DEMO_PID "$title" 16 $top 760 $(( 704 - top ))
r=($($AW ax find $DEMO_PID Widget)); $AW glide $r[1] $r[2] click
place_widget 796 $(( BAR + 16 ))
$AW activate $DEMO_PID
$AW glide 980 640
# The bottom row asks and the top one writes, so By state turns the list over. Which row is at the
# bottom changes from one stage to the next: rows come in the order the sessions first report.
for i in 1 2 3; do row_y[i]=$($AW ax find $DEMO_PID "$NAMES[i]" | awk '{ print $2 }'); done
asker=1 writer=1
for i in 2 3; do
  (( row_y[i] > row_y[asker] )) && asker=$i
  (( row_y[i] < row_y[writer] )) && writer=$i
done
sleep 1

take_begin settings $STAGE
sleep 0.8; mark tasks
say $NAMES[writer] "Without using any tools, write a 300-word note on why the app never polls when no session is active."
say $NAMES[asker] 'Run `git --version` and tell me the version in one line.'
sleep 4;   click findc "Order," order
sleep 1.4; click findc "By state" state
sleep 2.6; click find "Appearance" appearance
sleep 1.2; click find "Light" light
sleep 2.4; click find "Widget" widget
sleep 1.0; click findc "parts" rows
# Down to the lamp and the name, then two parts a fresh install leaves out.
for part in Elapsed Agent Counters Context; do sleep 0.9; click find $part off-${part:l}; done
sleep 1.4
for part in Branch Model; do sleep 1.0; click find $part on-${part:l}; done
sleep 0.6; $AW glide 980 640
sleep 2.0
take_end
# Answer the question it left, or the session waits through the next take.
press_in $NAMES[asker] enter
