#!/bin/zsh
# Other folders: two folders Claude Code can be started with, each chosen in the folder dialog from
# the Tooling page and given the hooks. Needs the hooks takes/setup.sh installed, or the page shows
# its guide instead of its rows, and default settings: stage.sh reset-settings first, which also
# makes the copy forget the folders an earlier try added.
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
# A work account and a personal one: why a person starts Claude Code with CLAUDE_CONFIG_DIR.
FOLDERS=(~/.claude-work ~/.claude-personal)
[[ -f ~/.claude/skills/agent-watch/hooks/hooks.json ]] || die "no Claude hooks: takes/setup.sh installs them, and without them Tooling shows its guide"
# Empty, as a new folder of a person's would be: the hooks an earlier try left would turn Install
# into Remove.
for f in $FOLDERS; do
  [[ ! -e $f ]] || discard $f
  mkdir $f
done
open_settings Tooling
win=($($AW ax windows $DEMO_PID | awk '$5 == "Tooling" { print $1, $2, $3, $4; exit }'))
(( $#win == 4 )) || die "no Tooling window"
sleep 1

take_begin folders $STAGE
sleep 0.8; mark tooling
for f in $FOLDERS; do
  # A mark's name is letters, digits and dashes (cut.py): work, personal.
  name=${${f:t}#.claude-}
  # Each folder's row goes in above Other folders and pushes its button down. Below the window's
  # bottom the button would still have a frame on the screen, over the Codex section. One search
  # serves the check and the click.
  button=($($AW ax findc $DEMO_PID "Add Folder"))
  (( button[2] < win[2] + win[4] - 20 )) || take_abort "Add Folder… is below the window: the page needs scrolling"
  sleep 0.4; glide_click $button[1] $button[2]; mark add-$name $button[3,6]
  # The dialog is a window of the copy's own, titled Open, so its rows are in the copy's
  # Accessibility tree. It opens in the home folder, in columns, with the dot-folders shown,
  # measured on macOS 15.7.7 in the virtual machine. The list of windows sees it come and go in
  # 0.05 s; a search for its text took 0.4 s, through every cell of its columns.
  for i in {1..40}; do $AW ax windows $DEMO_PID | grep -q " Open\$" && break; sleep 0.1; done
  $AW ax windows $DEMO_PID | grep -q " Open\$" || take_abort "the folder dialog did not open"
  sleep 0.6; click find ${f:t} pick-$name
  sleep 0.4; click find Add chosen-$name
  for i in {1..40}; do $AW ax windows $DEMO_PID | grep -q " Open\$" || break; sleep 0.1; done
  # The one Install in the Claude Code section, which comes first: the default folder and the
  # folders added before this one say Remove, the status line says Connect. Pressing another one
  # leaves this folder without hooks, and the check below stops the take.
  sleep 0.8; click find Install install-$name
  for i in {1..20}; do [[ -f $f/skills/agent-watch/hooks/hooks.json ]] && break; sleep 0.25; done
  [[ -f $f/skills/agent-watch/hooks/hooks.json ]] || take_abort "Install did not put the hooks into $f"
  mark installed-$name
  sleep 1.2
done
sleep 0.4; $AW glide 980 640
sleep 1.2
take_end
