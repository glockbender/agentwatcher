#!/bin/zsh
# The install clip: Agent Watch's first start, its guide installing the Claude Code hooks, and the
# first session, which the widget and then the guide show. Needs a machine where the hooks were
# never installed and nothing is open: vm.sh up bare, this take, then stage.sh up (vm.md).
set -e
source ${0:A:h}/../lib.sh
STAGE=(0 0 $($AW screen | awk '{ print $3, $4 }'))
PLUGIN=~/.claude/skills/agent-watch
# It ends every Claude Code process and quits Ghostty when it is done.
[[ $(sysctl -n kern.hv_vmm_present) == 1 ]] || die "takes/setup.sh runs only inside the virtual machine (vm.md): it ends every claude and quits Ghostty"
[[ ! -e $PLUGIN ]] || die "the Claude hooks are installed already ($PLUGIN): this take installs them on camera"
[[ -z $(pgrep -x AgentWatch) ]] || die "Agent Watch runs: this take starts it"
others=$($AW onscreen | sort -u | tr '\n' ' ')
[[ -z $others ]] || die "this desktop is not empty: $others"
[[ -d $DEMO_APP ]] || die "no $DEMO_APP: vm.sh up bare puts it there"
# A first start: the copy remembers nothing, and no stage is up.
[[ ! -e $SUPPORT ]] || trash $SUPPORT
rm -f $STATE
DEMO_PID=""
# The terminal opens on camera where it stays: Ghostty puts a new window where its configuration
# says, in points below the menu bar and in cells of open_terminal's font (Ghostty 1.3.1). Its
# bottom meets the settings window's, which macOS centres at 59–619 on this screen, measured on
# macOS 15.7.7: the clip ends there (clips/setup.keys).
print -- '\nwindow-position-x = 330\nwindow-position-y = 299\nwindow-width = 80\nwindow-height = 14' \
  >> ~/Library/Application\ Support/com.mitchellh.ghostty/config
# Below the clip, and above the edge that would bring up the Dock.
$AW glide 1060 680
sleep 1

take_begin setup $STAGE
sleep 1; mark launch
start_copy
for i in {1..20}; do widget_shown && break; sleep 0.25; done
widget_shown || take_abort "the widget did not show"
# Finding a button in the copy's Accessibility tree took about 1.5 s in a virtual machine, measured
# on macOS 15.7.7, on a screen that stands still meanwhile: the pauses before a click are short.
mark widget
sleep 0.8; click findc "Connect Agent" connect
sleep 0.3; click findc "Set Up Claude Code" choose
sleep 0.3; click findc "Install Connection" install
for i in {1..20}; do [[ -f $PLUGIN/hooks/hooks.json ]] && break; sleep 0.25; done
[[ -f $PLUGIN/hooks/hooks.json ]] || take_abort "the guide did not install the hooks"
sleep 0.3; click findc "Continue" continue
# Out of the way: the next page has "Finish Later" right under the pointer.
sleep 0.3; $AW glide 1060 560

# The terminal opens over the guide; the widget floats above both.
started=$(count_events sessionStarted)
sleep 1.2; mark terminal; open_terminal > /dev/null
sleep 1.2; mark claude; $AW type claude
sleep 0.3; $AW key 36
wait_events sessionStarted $started 30 || take_abort "the new session did not report: the installed hooks did not run"
mark started
# The guide's title bar stays above the terminal; a click there brings up its "✓".
sleep 1.5
settings=($($AW ax windows $DEMO_PID | awk 'NF > 4 { print $1, $2, $3; exit }'))
(( $#settings == 3 )) || take_abort "no settings window"
glide_click $(( settings[1] + settings[3] * 2 / 3 )) $(( settings[2] + 12 )); mark front
for i in {1..20}; do $AW ax findc $DEMO_PID "has reported" > /dev/null 2>&1 && break; sleep 0.25; done
$AW ax findc $DEMO_PID "has reported" > /dev/null 2>&1 && mark ready || mark ready-timeout
sleep 2.6
take_end

# An empty desktop for stage.sh up. The hooks stay installed; the stage's sessions do not read them.
for pid in $(pgrep -x claude); do kill -TERM $pid; done
sleep 1
$AW quit $(pgrep -x ghostty)
$AW quit $DEMO_PID
