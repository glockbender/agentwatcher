#!/bin/zsh
# Look: Light and a bright theme of one's own, the widget's size, and two lamps changed in the theme
# editor; each change shows on the widget at once. Lays the stage out as the order take does. The
# theme comes from stage.sh up (demo-theme.json); one session waits and another works through the
# take, so both lamps the editor changes are lit.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
open_settings Appearance
asked=$(count_events userInputRequired $ASKER)
sleep 1

take_begin look $STAGE
sleep 0.8; mark tasks
say $NAMES[3] "Read docs/architecture.md with the Read tool, no commands, and explain it in about 600 words."
say $NAMES[1] 'Run `task --list` and tell me in one line which task checks the documents.'
sleep 2.0; click find "Light" light
sleep 1.8; click findc "Default" theme-menu
sleep 0.9; click findm "Bubblegum" theme
# The size menu opens around the current size in steps of 5 %, and 150 % hung below the screen's
# bottom: 125 % and 75 % are the farthest it shows.
sleep 2.4; click findc "100%" size-menu
sleep 0.9; click findm "125%" bigger
sleep 2.2; click findc "125%" size-menu-2
sleep 0.9; click findm "75%" smaller
sleep 2.2; click findc "75%" size-menu-3
sleep 0.9; click findm "100%" size-back
sleep 2.0; click findc "Edit Theme" edit
# The lamps are below the window's bottom.
sleep 1.0; $AW glide 400 400; $AW scroll 300 0.8; mark scrolled
wait_events userInputRequired $asked 30 $ASKER || take_abort "Check the task list did not ask"
# Waiting for you: from orange into red instead of yellow. It already fades at the fastest cycle the
# editor allows (LampStyle.animationCycleRange starts at 0.5 s), so Working is the lamp sped up.
column=($($AW ax findw $DEMO_PID "Edit Theme" "To color"))
row=($($AW ax findw $DEMO_PID "Edit Theme" "Waiting for you"))
sleep 0.6; glide_click $column[1] $row[2]; mark to-color
# The colour panel opens on its wheel, red at the wheel's right edge: 186 and 142 points from the
# panel's top left corner, measured on macOS 15.7.7.
sleep 1.0
panel=($($AW ax windows $DEMO_PID | awk '$NF == "Colors" { print $1, $2; exit }'))
(( $#panel == 2 )) || take_abort "the colour panel did not open"
glide_click $(( panel[1] + 186 )) $(( panel[2] + 142 )); mark red
sleep 1.0; $AW ax close $DEMO_PID Colors
# The slider is about 33 points long for 0.5 to 10 s: from 2.5 s to the left end.
column=($($AW ax findw $DEMO_PID "Edit Theme" "Full cycle"))
row=($($AW ax findw $DEMO_PID "Edit Theme" "Working"))
sleep 0.8; drag_to $(( column[3] + 41 )) $row[2] $(( column[3] + 10 )) $row[2]; mark faster
sleep 0.6; $AW glide 980 640
# Time for the camera to close in on the lamps and come back out (clips/theme.keys).
sleep 4.2
take_end
# Answer the question it left, or the session waits through the next take.
press_in $NAMES[1] enter
