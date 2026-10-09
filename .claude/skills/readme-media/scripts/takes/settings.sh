#!/bin/zsh
# Settings: each change shows on the widget beside the window at once. Needs default settings —
# after a settings take, run stage.sh reset-settings before the next one.
set -e
source ${0:A:h}/../lib.sh
STAGE=(560 0 1152 640)
place_sessions 0 $BAR 540 $(( 638 - BAR ))
show_widget
$AW ax press $DEMO_PID showWidgetSettings
sleep 1.5
title=$($AW ax windows $DEMO_PID | awk 'NF > 4 { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }')
[[ -n $title ]] || die "the settings window did not open"
$AW ax move $DEMO_PID "$title" 560 $BAR 745 $(( 638 - BAR ))
r=($($AW ax find $DEMO_PID Widget)); $AW glide $r[1] $r[2] click
place_widget 1318 $(( BAR + 42 ))
# Black behind the widget, so the desktop picture does not show around it.
$AW backdrop 1305 $BAR 423 $(( 640 - BAR )) &
backdrop=$!
# Gone with the take, however it ends: left running, it held `tart exec` open for 20 minutes.
AT_EXIT+=('kill $backdrop 2> /dev/null')
$AW activate $DEMO_PID
$AW glide 1000 520
sleep 1

take_begin settings $STAGE
sleep 0.8; mark tasks
say $NAMES[3] "Without using any tools, write a 300-word note on why the app never polls when no session is active."
say $NAMES[1] 'Run `git --version` and tell me the version in one line.'
sleep 4;   click findc "Order," order
sleep 1.4; click findc "By state" state
sleep 2.6; click find "Appearance" appearance
sleep 1.2; click find "Light" light
sleep 2.4; click find "Widget" widget
sleep 1.0; click findc "parts" rows
sleep 1.4; click find "Branch" branch
sleep 2.2; click find "Menu Bar" menubar
sleep 1.2; click find "Counts" counts
sleep 1.0; $AW glide 1000 520
sleep 2.0
take_end
kill $backdrop
# Answer the question it left, or the session waits through the next take.
press_in $NAMES[1] enter
