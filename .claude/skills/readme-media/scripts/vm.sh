#!/bin/zsh
# vm.sh stand | grant | up [bare] | sync | run <take> | fetch | down | sh <command>
#
# Takes the README clips in a clean macOS inside a Tart virtual machine: nothing of this Mac's
# desktop gets into a frame, and a take's clicks and keys stay inside the machine. vm.md tells the
# whole process and why each step is there.
#
#   stand   make aw-stand from aw-golden: screen, ffmpeg, Ghostty, Claude Code, task. Once.
#   grant   open aw-stand in a window for the two permissions only a person may give. Once.
#   up      clone aw-stand into aw-take and put the stage up there, as stage.sh up does here;
#           `up bare` stops before the stage, for takes/setup.sh, which needs nothing open
#   sync    give the running aw-take this skill's files again, after a script changed here
#   run     run a take inside aw-take: vm.sh run takes/hero.sh
#   fetch   copy aw-take's new recordings and marks into this Mac's cache, where cut.py looks;
#           `fetch hero menu` copies those takes whatever is here
#   down    stop aw-take and move it to the Trash
#   sh      run a command inside aw-take, or inside the machine AW_VM names
set -e

SCRIPTS=${0:A:h}
REPO=$(git -C $SCRIPTS rev-parse --show-toplevel)
WORK=~/Library/Caches/agent-watch-media
# Shared with the machine; it sees this folder as $G_SHARE.
SHARE=$WORK/vm-share
GOLDEN=aw-golden
STAND=aw-stand
TAKE_VM=aw-take
VM=${AW_VM:-$TAKE_VM}
# The token Claude Code signs in with. Its owner put it into this Mac's keychain (vm.md); it goes
# into a machine's keychain through a pipe and never into a command line, a file or a log.
TOKEN=agent-watch-vm-claude-token
# The screen the takes were laid out on, in points: a 16-inch MacBook Pro's.
SCREEN=(1728 1117)
G_REPO=/Users/admin/CommonProjects/agent-watch
G_SCRIPTS=$G_REPO/.claude/skills/readme-media/scripts
G_WORK=/Users/admin/Library/Caches/agent-watch-media
G_SHARE="/Volumes/My Shared Files/aw"
G_TCC="/Users/admin/Library/Application Support/com.apple.TCC/TCC.db"
# What stage.sh would otherwise build or read on this Mac.
G_ENV="AW_PREBUILT=1 AW_CLAUDE_HOOKS=$G_WORK/claude-hooks.json"
path=(~/.local/bin $path)
mkdir -p $SHARE

die() { print -u2 -- "$*"; exit 1 }
say_step() { print -- "· $*" }

# A login shell, for Homebrew's PATH and the token's line in ~/.zshenv.
in() { local vm=$1; shift; tart exec $vm zsh -lc "$*" }
in_stdin() { local vm=$1; shift; tart exec -i $vm zsh -lc "$*" }
running() { tart get $1 --format json 2>/dev/null | grep -q '"Running" : true' }

boot() { # <vm> [window]
  local vm=$1 i
  if ! running $vm; then
    local args=(--dir=aw:$SHARE)
    [[ ${2:-} == window ]] || args+=(--no-graphics)
    nohup tart run $args $vm > $WORK/$vm.log 2>&1 &!
  fi
  for i in {1..90}; do in $vm 'pgrep -x Dock' > /dev/null 2>&1 && break; sleep 2; done
  in $vm 'pgrep -x Dock' > /dev/null 2>&1 || die "$vm did not start: $WORK/$vm.log"
  # The desktop needs a moment after the Dock; a window opened before it can land behind.
  sleep 5
}

# The checkout the sessions run in, as a plain clone on a branch named main: rows show it. Changes
# not yet committed here go along, so a take can be tried before its commit.
sync_repo() { # <vm>
  local branch=$(git -C $REPO symbolic-ref --short HEAD)
  git -C $REPO bundle create -q $SHARE/repo.bundle $branch
  git -C $REPO diff HEAD --binary > $SHARE/repo.diff
  (cd $REPO && git ls-files -o --exclude-standard) > $SHARE/repo-untracked.txt
  (cd $REPO && tar -cf $SHARE/repo-untracked.tar -T $SHARE/repo-untracked.txt 2>/dev/null) || tar -cf $SHARE/repo-untracked.tar -T /dev/null
  in $1 "{ [[ ! -e $G_REPO ]] || trash $G_REPO } && mkdir -p ${G_REPO:h} \
    && git clone -q -b $branch '$G_SHARE/repo.bundle' $G_REPO && cd $G_REPO && git checkout -q -B main \
    && { [[ ! -s '$G_SHARE/repo.diff' ]] || git apply '$G_SHARE/repo.diff' } && tar -xf '$G_SHARE/repo-untracked.tar'"
}

screen() { # <vm>
  in $1 "$G_SCRIPTS/aw-media display $SCREEN" > /dev/null
  [[ $(in $1 "$G_SCRIPTS/aw-media screen" | awk '{ print $3, $4 }') == "$SCREEN" ]] || die "$1 kept another screen size"
}

# Built here, where the developer certificate is: a copy signed with it keeps the permission to
# drive Ghostty that `grant` gave the copy before it. One the machine signs itself would not.
push_app() { # <vm>
  say_step "building the debug copy"
  $REPO/scripts/build-app.sh debug $SHARE/AgentWatch.app > $WORK/vm-build.log 2>&1 || die "build failed: $WORK/vm-build.log"
  local hooks=~/.claude/skills/agent-watch/hooks/hooks.json
  [[ -f $hooks ]] || die "no $hooks: install the Claude hooks from Agent Watch on this Mac first"
  cp $hooks $SHARE/claude-hooks.json
  in $1 "mkdir -p $G_WORK && { [[ ! -e $G_WORK/AgentWatch.app ]] || trash $G_WORK/AgentWatch.app } \
    && ditto '$G_SHARE/AgentWatch.app' $G_WORK/AgentWatch.app && cp '$G_SHARE/claude-hooks.json' $G_WORK/"
}

push_token() { # <vm>
  security find-generic-password -s $TOKEN > /dev/null 2>&1 || die "no $TOKEN in this Mac's keychain: vm.md says how to put it there"
  # `security -i` reads the command from the pipe, so the token is in no process's arguments.
  security find-generic-password -s $TOKEN -w \
    | tart exec -i $1 zsh -c "read -r t && print -r -- \"add-generic-password -U -a admin -s $TOKEN -w \$t\" | security -i > /dev/null 2>&1"
  in $1 "security find-generic-password -s $TOKEN > /dev/null 2>&1" || die "the token did not reach $1's keychain"
}

# The stand is kept and cloned, so it must not keep the person's account: the token, and what
# Claude Code wrote down about the account it signed in to.
scrub_account() { # <vm>
  in $1 "security delete-generic-password -s $TOKEN > /dev/null 2>&1; python3 - <<'EOF'
import json, pathlib
path = pathlib.Path.home() / '.claude.json'
config = json.loads(path.read_text())
for key in ('oauthAccount', 'userID', 'anonymousId', 'claudeCodeFirstTokenDate'):
    config.pop(key, None)
path.write_text(json.dumps(config, indent=2))
EOF"
  in $1 "security find-generic-password -s $TOKEN > /dev/null 2>&1" && die "the token is still in $1's keychain"
  return 0
}

# Claude Code keeps a record of a start until the process exits, and counts a record it finds left
# over as a failed start of its fullscreen renderer; after a few it draws the plain one with a notice
# on every screen (measured on Claude Code 2.1.294). The stand's own starts must not count.
forget_failed_starts() { # <vm>
  in $1 "python3 - <<'EOF'
import json, pathlib
path = pathlib.Path.home() / '.claude.json'
config = json.loads(path.read_text())
for key in ('fullscreenBootStrikes', 'fullscreenBootPending'):
    config.pop(key, None)
path.write_text(json.dumps(config, indent=2))
EOF"
}

stage_env() { print -- "cd $G_SCRIPTS && $G_ENV" }

# macOS reopens at login what ran when the machine stopped, and a stage needs an empty desktop.
quit_ghostty() { # <vm>
  in $1 "if pgrep -x ghostty > /dev/null; then $G_SCRIPTS/aw-media quit \$(pgrep -x ghostty); sleep 2; fi"
}

case ${1:-} in
stand)
  if ! tart get $STAND > /dev/null 2>&1; then
    say_step "cloning $GOLDEN into $STAND"
    tart clone $GOLDEN $STAND
  fi
  running $STAND || tart set $STAND --cpu 8 --memory 16384 --display ${SCREEN[1]}x${SCREEN[2]}pt
  boot $STAND
  sync_repo $STAND
  screen $STAND
  # A plain dark grey instead of the machine's forest, which stood behind every take and cost the
  # encoder most of a clip's size.
  in $STAND "$G_SCRIPTS/aw-media wallpaper '/System/Library/Desktop Pictures/Solid Colors/Stone.png'"
  # Dark, as the owner's Mac was when the takes were laid out: under a light system the widget's
  # Auto is already light, and choosing Light in the settings take changed nothing on screen. It
  # takes effect at the next login, and every copy starts with one.
  in $STAND "defaults write -g AppleInterfaceStyle -string Dark"
  say_step "ffmpeg"
  in $STAND 'brew list ffmpeg > /dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew install --quiet ffmpeg'

  ghostty=$(defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString)
  say_step "Ghostty $ghostty and its configuration"
  if [[ $(in $STAND 'defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null') != $ghostty ]]; then
    ditto /Applications/Ghostty.app $SHARE/Ghostty.app
    in $STAND "{ [[ ! -e /Applications/Ghostty.app ]] || sudo trash /Applications/Ghostty.app } && sudo ditto '$G_SHARE/Ghostty.app' /Applications/Ghostty.app"
  fi
  # This Mac's look, and no updates: a new copy asks in its title bar whether to check for them,
  # and the button stays there through every take. Every new window opens at this place and size —
  # points from the top left below the menu bar, and cells — so a take opens a terminal on camera
  # without it jumping (Ghostty 1.3.1). The file may end without a newline: it starts one.
  cp ~/Library/Application\ Support/com.mitchellh.ghostty/config $SHARE/ghostty-config
  print -- '\nauto-update = off\nwindow-position-x = 620\nwindow-position-y = 150\nwindow-width = 88\nwindow-height = 27' \
    >> $SHARE/ghostty-config
  in $STAND "mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty && cp '$G_SHARE/ghostty-config' ~/Library/Application\ Support/com.mitchellh.ghostty/config"

  # Claude.app for its icon alone, never started: a row shows the app's logo, and without the app a
  # plain orange disc, which reads as a second lamp. Registered at once, as the Finder would.
  desktop=$(defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString)
  say_step "Claude.app $desktop, for its icon"
  if [[ $(in $STAND 'defaults read /Applications/Claude.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null') != $desktop ]]; then
    ditto /Applications/Claude.app $SHARE/Claude-$desktop.app
    in $STAND "{ [[ ! -e /Applications/Claude.app ]] || sudo trash /Applications/Claude.app } \
      && sudo ditto '$G_SHARE/Claude-$desktop.app' /Applications/Claude.app \
      && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Claude.app"
    trash $SHARE/Claude-$desktop.app
  fi

  # Copied rather than installed: the same build as here, and nothing downloaded from inside.
  claude=$(readlink ~/.local/bin/claude)
  say_step "Claude Code ${claude:t} and task"
  cp -f $claude $SHARE/claude
  cp -f $(command -v task) $SHARE/task
  in $STAND "mkdir -p ~/.local/share/claude/versions ~/.local/bin && cp -f '$G_SHARE/claude' ~/.local/share/claude/versions/${claude:t} \
    && ln -sf ~/.local/share/claude/versions/${claude:t} ~/.local/bin/claude && cp -f '$G_SHARE/task' ~/.local/bin/task"
  # The file holds the command that reads the token, not the token.
  in_stdin $STAND "cat > ~/.zshenv" <<EOF
path=(~/.local/bin /opt/homebrew/bin \$path)
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
CLAUDE_CODE_OAUTH_TOKEN=\$(security find-generic-password -s $TOKEN -w 2>/dev/null) && export CLAUDE_CODE_OAUTH_TOKEN
EOF
  # A shell a take types into on camera: no "Last login" line, nothing of this machine in the
  # prompt, and `claude` starting as the stage's sessions do (stage.sh) when the take asks for it.
  in $STAND 'touch ~/.hushlogin'
  in_stdin $STAND "cat > ~/.zshrc" <<'EOF'
PROMPT='%~ %# '
[[ -n $AW_DEMO_SETTINGS ]] && claude() {
  local demo=(--setting-sources project,local --strict-mcp-config --settings $AW_DEMO_SETTINGS --permission-mode default)
  # An array: zsh keeps ${name:+--name "$name"} one word, and Claude refused "--name Count the tasks".
  [[ -z $AW_SESSION_NAME ]] || demo+=(--name "$AW_SESSION_NAME")
  command claude $demo "$@"
}
EOF
  # What a plain `claude` reads, for the setup clip, whose session uses the hooks it installs: the
  # stage's look without its hooks. Its footer says "manual mode on", as the stage's sessions do,
  # instead of "auto mode on", the default measured on Claude Code 2.1.294.
  in $STAND "mkdir -p ~/.claude && python3 - <<'EOF'
import json, pathlib
path = pathlib.Path.home() / '.claude/settings.json'
settings = json.loads(path.read_text()) if path.exists() else {}
settings.update(spinnerVerbs={'mode': 'replace', 'verbs': ['Working', 'Thinking', 'Reading']},
                spinnerTipsEnabled=False, preferredNotifChannel='notifications_disabled')
settings.setdefault('permissions', {})['defaultMode'] = 'default'
path.write_text(json.dumps(settings, indent=2))
EOF"
  # What a first start would ask: a theme, and whether the checkout is trusted. Hooks run only in a
  # trusted folder, and IS_DEMO skips the question without keeping the answer.
  in $STAND "python3 - <<'EOF'
import json, pathlib
path = pathlib.Path.home() / '.claude.json'
config = json.loads(path.read_text()) if path.exists() else {}
config.update(hasCompletedOnboarding=True, lastOnboardingVersion='${claude:t}', lastReleaseNotesSeen='${claude:t}',
              theme='dark', autoUpdates=False, numStartups=10)
project = config.setdefault('projects', {}).setdefault('$G_REPO', {})
project.update(hasTrustDialogAccepted=True, hasClaudeMdExternalIncludesApproved=True,
               hasClaudeMdExternalIncludesWarningShown=True)
path.write_text(json.dumps(config, indent=2))
EOF"

  # Claude Code's first start with the token, printed rather than met on camera. The settings the
  # organisation manages are approved only with AW_APPROVE_MANAGED_SETTINGS=1, which the owner of
  # the account allows for that account (vm.md); the stand keeps the approval and loses the account.
  say_step "Claude Code's first start"
  approve=()
  [[ ${AW_APPROVE_MANAGED_SETTINGS:-} != 1 ]] || approve=(--approve-managed-settings)
  push_token $STAND
  # Whatever stops the first start, the stand must not keep the account.
  trap "scrub_account $STAND > /dev/null 2>&1 || true" EXIT
  in $STAND "cd $G_REPO && python3 $G_SCRIPTS/claude-first-start.py $approve" \
    || die "Claude Code did not reach its prompt: see above; managed settings need AW_APPROVE_MANAGED_SETTINGS=1 (vm.md)"
  scrub_account $STAND
  trap - EXIT
  forget_failed_starts $STAND

  # Ghostty's first start posts a banner about its Dock tile; burned here, it never lands in a take.
  say_step "Ghostty's first start"
  in $STAND "open -a Ghostty && sleep 6 && $G_SCRIPTS/aw-media quit \$(pgrep -x ghostty) && sleep 2 && $G_SCRIPTS/aw-media clear-notifications"
  quit_ghostty $STAND
  tart stop $STAND
  say_step "$STAND is ready; vm.sh grant next, unless it was done before"
  ;;

grant)
  boot $STAND window
  sync_repo $STAND
  screen $STAND
  push_app $STAND
  push_token $STAND
  # Whatever stops this, the stand must not keep the account.
  trap "scrub_account $STAND > /dev/null 2>&1 || true" EXIT
  say_step "1/2 — in the machine's window, allow tart-guest-agent to control Ghostty"
  in $STAND 'open -a Ghostty' && sleep 3
  for i in {1..300}; do
    in $STAND 'osascript -e "tell application \"Ghostty\" to count windows"' > /dev/null 2>&1 && break
    sleep 2
  done
  in $STAND 'osascript -e "tell application \"Ghostty\" to count windows"' > /dev/null 2>&1 || die "Ghostty is still not allowed"
  in $STAND "$G_SCRIPTS/aw-media quit \$(pgrep -x ghostty)"
  sleep 2
  in $STAND "$(stage_env) ./stage.sh up"
  say_step "2/2 — in the machine's window, allow AgentWatch to control Ghostty"
  # A click on the waiting row sends the first Apple event, and with it the question.
  in $STAND "source $G_SCRIPTS/lib.sh && show_widget && r=(\$(\$AW ax find \$DEMO_PID \"\$NAMES[1]\")) && \$AW glide \$r[1] \$r[2] click"
  for i in {1..300}; do
    [[ $(in $STAND "sqlite3 '$G_TCC' \"select auth_value from access where client = 'com.glockbender.agentwatch' and indirect_object_identifier = 'com.mitchellh.ghostty'\"") == 2 ]] && break
    sleep 2
  done
  in $STAND "$(stage_env) ./stage.sh down"
  scrub_account $STAND
  quit_ghostty $STAND
  tart stop $STAND
  [[ $i -lt 300 ]] || die "AgentWatch is still not allowed to control Ghostty"
  say_step "both granted; $STAND is ready for vm.sh up"
  ;;

up)
  tart get $TAKE_VM > /dev/null 2>&1 && die "$TAKE_VM is there already: vm.sh down first"
  running $STAND && die "$STAND runs: it is cloned stopped"
  tart clone $STAND $TAKE_VM
  boot $TAKE_VM
  sync_repo $TAKE_VM
  screen $TAKE_VM
  push_app $TAKE_VM
  push_token $TAKE_VM
  quit_ghostty $TAKE_VM
  [[ ${2:-} == bare ]] || in $TAKE_VM "$(stage_env) ./stage.sh up"
  ;;

run)
  shift
  [[ -n ${1:-} ]] || die "vm.sh run <take> [arguments]"
  in $VM "$(stage_env) ./${(j: :)${(q)@}}"
  ;;

fetch)
  shift
  # Through the shared folder: a take is up to a gigabyte of ProRes, so the marks come first and a
  # recording follows only when its marks are not here yet. Copying every take each time took
  # minutes. A take that failed in the machine stays there: it would replace a good one here. A new
  # folder each time: the machine refused to write a name that had been moved away here, as it kept
  # reading old contents (sync).
  box=fetch-$(date +%s)
  mkdir $SHARE/$box
  in $VM "cd $G_WORK && for f in *.marks(N); do cp \$f '$G_SHARE/$box/'; done"
  takes=($@)
  if (( ! $#takes )); then
    for f in $SHARE/$box/*.marks(N); do
      cmp -s $f $WORK/${f:t} && continue
      if grep -qx failed $f; then say_step "${f:t:r} failed in the machine: the one here stays"; continue; fi
      takes+=(${f:t:r})
    done
  fi
  for take in $takes; do
    say_step "fetching $take"
    in $VM "cp $G_WORK/$take.mov '$G_SHARE/$box/'"
    mv $SHARE/$box/$take.mov $WORK/ && cp $SHARE/$box/$take.marks $WORK/
  done
  trash $SHARE/$box
  say_step "fetched: ${takes:-nothing new}"
  ;;

down)
  if running $TAKE_VM; then
    in $TAKE_VM "$(stage_env) ./stage.sh down" || true
    # The Trash keeps the clone until it is emptied, and its keychain with it.
    scrub_account $TAKE_VM
    tart stop $TAKE_VM
  fi
  # The Trash keeps the clone's own blocks until it is emptied; the rest it shares with the stand.
  [[ ! -e ~/.tart/vms/$TAKE_VM ]] || trash ~/.tart/vms/$TAKE_VM
  say_step "$TAKE_VM is in the Trash"
  ;;

sync)
  # The skill's own files only: the sessions run inside the checkout, and replacing it under them
  # would leave them working in the Trash. A new name each time: a running machine kept reading the
  # old contents of a file rewritten in place in the shared folder (Tart 2.40.1).
  rm -f $SHARE/skill-*.tar(N)
  archive=skill-$(date +%s).tar
  tar -C $REPO -cf $SHARE/$archive .claude/skills/readme-media
  in $VM "tar -C $G_REPO -xf '$G_SHARE/$archive'"
  ;;

sh)
  shift
  in $VM "$*"
  ;;

*)
  sed -n '2,14p' $0
  exit 2
  ;;
esac
