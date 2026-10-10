#!/bin/zsh
# Rows: parts of a row go off one by one, two others come on, then the widget is stretched wider by
# its left edge and back, and the rows follow. Lays the stage out as the order take does.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
open_settings Widget
sleep 1

take_begin rows $STAGE
sleep 0.8; click findc "parts" rows
# Down to the lamp and the name, then two parts a fresh install leaves out.
for part in Elapsed Agent Counters Context; do sleep 0.9; click find $part off-${part:l}; done
sleep 1.4
for part in Branch Model; do sleep 1.0; click find $part on-${part:l}; done
sleep 1.2
# The left edge, the one away from the screen's: wider until every name fits, then back, where the
# long names are cut short again. A press in the six points inside the edge resizes
# (docs/widget-window.md, «Размер»). Not narrower than at the start: that is near the narrowest the
# widget goes (HUDFrameStore.minimumSize), and dragged past it the edge stopped while the pointer
# went on over the rows, a card opened, and the next press moved the widget instead. After each drag
# the pointer steps off the widget, as resting on a row for half a second opens its card.
w=($($AW ax windows $DEMO_PID | awk 'NF == 4 { print; exit }'))
y=$(( w[2] + w[4] / 2 ))
sleep 0.4; drag_to $(( w[1] + 2 )) $y $(( w[1] - 198 )) $y; mark wider
$AW glide $(( w[1] - 240 )) $y
sleep 1.8; drag_to $(( w[1] - 198 )) $y $(( w[1] + 2 )) $y; mark back
sleep 0.4; $AW glide 980 640
sleep 1.6
# The right edge stays put, which tells the widget from a card that might be open.
f=($($AW ax windows $DEMO_PID | awk -v r=$(( w[1] + w[3] )) 'NF == 4 && $1 + $3 == r { print; exit }'))
(( ${f[3]:-0} == w[3] )) || take_abort "the widget is ${f[3]:-gone} points wide after the drags, not $w[3]"
take_end
