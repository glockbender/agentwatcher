#!/bin/zsh
# Runs inside the machine, from the folder `e2e-update.sh` shares with it: every update case
# against the local server, one line per case in out/result.txt, and what each window said beside
# it. A case starts from the old copy (0.9.0) installed and Sparkle's memory of it forgotten.
# `machine.sh published <version>` runs the one case for a published release instead.
set -u
share="/Volumes/My Shared Files/aw"
out="$share/out"
mkdir -p "$out"
ax=~/ax
cp "$share/ax" $ax
port=8123
copy=/Applications/AgentWatch.app
sparkle_cache=~/Library/Caches/com.glockbender.agentwatch/org.sparkle-project.Sparkle

say() { print -- "[$(date +%H:%M:%S)] $*" | tee -a "$out/run.log" }
result() { print -- "$1 $2${3:+ — $3}" | tee -a "$out/result.txt" }
shot() { screencapture -x "$out/$1.png" 2>/dev/null }
app_pid() { pgrep -f "$copy/Contents/MacOS/AgentWatch\$" | head -1 }
installed() { plutil -extract CFBundleShortVersionString raw -o - $copy/Contents/Info.plist }
windows_say() { $ax text $1 2>/dev/null }
# Waits up to <seconds> for any of the app's windows to say <pattern> (grep -E, case ignored).
wait_for() { # <pid> <pattern> <seconds>
  local i
  for i in {1..$3}; do windows_say $1 | grep -q -i -E -- "$2" && return 0; sleep 1; done
  return 1
}

quit_app() {
  local pid=$(app_pid) i
  [[ -n $pid ]] || return 0
  kill $pid
  for i in {1..20}; do kill -0 $pid 2>/dev/null || return 0; sleep 0.5; done
  kill -9 $pid 2>/dev/null
}

fresh() {
  quit_app
  rm -rf $copy
  ditto "$share/old/AgentWatch.app" $copy
  defaults delete com.glockbender.agentwatch > /dev/null 2>&1
  rm -rf ~/Library/Caches/com.glockbender.agentwatch
  touch ~/.case-start
}

# A download cut short leaves its part in the temp folder (measured on macOS 15.7.7). macOS's own
# downloader keeps it, not Sparkle, and macOS clears that folder itself, so it is reported, not
# failed. The folder is shared by every program of this account: nothing here may clean it.
partials() {
  find "$(getconf DARWIN_USER_TEMP_DIR)" -maxdepth 1 -name 'CFNetworkDownload_*' -newer ~/.case-start \
    2> /dev/null | wc -l | tr -d ' '
}

# Starts the installed copy against a feed; sets $pid. Sparkle looks five seconds after launch.
start() { # <case> <feed url>
  open --env AGENT_WATCH_UPDATE_FEED=$2 --env AGENT_WATCH_UPDATE_DIAGNOSTICS=1 --stderr "$out/$1-stderr.log" $copy
  local i
  pid=""
  for i in {1..20}; do pid=$(app_pid); [[ -n $pid ]] && return 0; sleep 0.5; done
  return 1
}

# The old copy is in place, whole, and still running, and Sparkle's folders hold nothing of the
# attempt: what every failure must leave behind.
untouched() {
  [[ $(installed) == 0.9.0 ]] || { print "installed $(installed)"; return 1 }
  codesign --verify --strict $copy 2> /dev/null || { print "codesign --strict fails"; return 1 }
  kill -0 $pid 2> /dev/null || { print "the app quit"; return 1 }
  local left=$(find $sparkle_cache -mindepth 2 2> /dev/null | sed "s|^$sparkle_cache/||" | tr '\n' ' ')
  [[ -z $left ]] || { print "Sparkle left $left"; return 1 }
}

# A check that fails before any offer: nothing on screen, nothing changed.
quiet_failure() { # <case> <feed url>
  fresh
  start $1 $2 || { result $1 FAILED "did not start"; return }
  sleep 15
  if windows_say $pid | grep -q -i -E 'Install Update|error'; then
    shot $1; windows_say $pid > "$out/$1.txt"; result $1 FAILED "a window appeared"; return
  fi
  local why
  why=$(untouched) && result $1 passed "no window, copy untouched" || result $1 FAILED "$why"
}

# An offer accepted, then a download or a check that fails: an error, then nothing changed.
failed_download() { # <case> <feed url> <seconds to wait for the error>
  fresh
  start $1 $2 || { result $1 FAILED "did not start"; return }
  wait_for $pid 'Install Update' 30 || { shot $1; result $1 FAILED "no offer"; return }
  $ax press $pid "Install Update"
  if ! wait_for $pid 'error|could not|failed|improperly' $3; then
    shot $1; windows_say $pid > "$out/$1.txt"
    windows_say $pid | grep -q 'Install and Relaunch' && result $1 FAILED "it was offered for install" \
      || result $1 FAILED "no error in $3 s"
    return
  fi
  shot $1
  windows_say $pid > "$out/$1.txt"
  local said=$(grep -i -m1 -E 'error|could not|failed|improperly' "$out/$1.txt")
  $ax press $pid OK 2> /dev/null || $ax press $pid Cancel 2> /dev/null
  sleep 1
  local why note=""
  (( $(partials) )) && note="; a partial download stays in the temp folder"
  why=$(untouched) && result $1 passed "said: $said$note" || result $1 FAILED "$why"
}

# The copy sits in a folder this account cannot write to, as when another administrator installed
# it: Sparkle asks for an administrator's password, right after the download (measured on macOS
# 15.7.7). The person cancels, and the update ends quietly with the copy untouched. Typing the
# password is left out: what follows it is Sparkle's own installer, run by macOS as root.
no_write_access() {
  local saved=$copy agent="" i why
  quit_app
  copy=~/ReadOnly/AgentWatch.app
  fresh
  chmod 555 ${copy:h}
  if ! start no-write-access $(feed good); then
    result no-write-access FAILED "did not start"
  elif ! wait_for $pid 'Install Update' 30; then
    shot no-write-access; result no-write-access FAILED "no offer"
  else
    $ax press $pid "Install Update"
    # The prompt belongs to SecurityAgent, not to the app.
    for i in {1..60}; do
      agent=$(pgrep -x SecurityAgent | head -1)
      [[ -n $agent ]] && $ax text $agent 2> /dev/null | grep -q 'wants permission to update' && break
      agent=""
      sleep 1
    done
    shot no-write-access
    if [[ -z $agent ]]; then
      windows_say $pid > "$out/no-write-access.txt"; result no-write-access FAILED "no password prompt"
    else
      $ax text $agent > "$out/no-write-access.txt"
      $ax press $agent Cancel
      sleep 5
      if windows_say $pid | grep -q -i -E 'Install Update|Install and Relaunch|error'; then
        shot no-write-access-after; result no-write-access FAILED "a window stayed after Cancel"
      else
        why=$(untouched) && result no-write-access passed "asked for a password; Cancel left the copy untouched" \
          || result no-write-access FAILED "$why"
      fi
    fi
  fi
  quit_app
  chmod 755 ${copy:h}
  copy=$saved
}

# Presses Install and Relaunch in the running copy and checks what came back: <version> installed,
# a new process running it, the bundle whole, and no word from macOS that it stopped the change.
relaunch_into() { # <case> <version>
  local old=$pid i blocked
  if ! wait_for $old 'Install and Relaunch' 120; then
    shot $1; windows_say $old > "$out/$1.txt"; result $1 FAILED "no Install and Relaunch"; return
  fi
  # The press quits the app before Accessibility can answer: gone means pressed.
  for i in {1..20}; do
    $ax press $old "Install and Relaunch" 2> /dev/null && break
    sleep 1
    kill -0 $old 2> /dev/null || break
  done
  for i in {1..60}; do pid=$(app_pid); [[ -n $pid && $pid != $old ]] && break; sleep 1; done
  sleep 2
  shot $1
  # `log show` writes its own command line, the predicate in it, into the log it reads: without
  # `process != "log"` it finds itself (measured on macOS 15.7.7).
  blocked=$(/usr/bin/log show --last 5m --style compact \
    --predicate 'eventMessage CONTAINS[c] "prevented from modifying apps" AND process != "log"' 2> /dev/null \
    | grep -c -i 'prevented')
  if [[ $(installed) == $2 && -n $pid && $pid != $old ]] && codesign --verify --strict $copy 2> /dev/null \
    && [[ $blocked == 0 ]]; then
    result $1 passed "$2 installed and running, macOS did not block it"
  else
    result $1 FAILED "installed $(installed), pid ${pid:-none} (was $old), blocked lines $blocked"
  fi
}

# After a release is published: the earlier release in old/, as a person has it, started with
# nothing pointed anywhere, finds <version> on GitHub and replaces itself with it. Its own updater
# (0.3.0) offers Download, Sparkle offers Install Update; both end in Install and Relaunch.
if [[ ${1:-} == published ]]; then
  : > "$out/result.txt"
  say "macOS $(sw_vers -productVersion): $(plutil -extract CFBundleShortVersionString raw -o - "$share/old/AgentWatch.app/Contents/Info.plist") to $2"
  fresh
  open --stderr "$out/published-stderr.log" $copy
  pid=""
  for i in {1..20}; do pid=$(app_pid); [[ -n $pid ]] && break; sleep 0.5; done
  if [[ -z $pid ]]; then
    result published FAILED "did not start"
  elif ! wait_for $pid "$2 is (now )?available" 90; then
    shot published; windows_say $pid > "$out/published.txt"; result published FAILED "no offer of $2 in 90 s"
  else
    windows_say $pid > "$out/offer.txt"
    $ax press $pid "Install Update" 2> /dev/null || $ax press $pid Download
    relaunch_into published $2
  fi
  quit_app
  exit 0
fi

feed() { print "http://127.0.0.1:$port/feed/$1.xml" }

pkill -f "server.py" 2> /dev/null
rm -rf ~/serve && ditto "$share/serve" ~/serve
nohup python3 "$share/server.py" ~/serve $port > "$out/server.log" 2>&1 &!
sleep 1
: > "$out/result.txt"
say "macOS $(sw_vers -productVersion)"

quiet_failure feed-broken $(feed broken)
quiet_failure feed-unreachable "http://127.0.0.1:9/appcast.xml"
failed_download download-error $(feed error) 30
failed_download download-dropped $(feed drop) 30
failed_download download-stalled $(feed stall) 120
failed_download bad-signature $(feed badsig) 30

# The person tries again after a failure — Sparkle's memory of it kept, the old copy relaunched —
# and the update goes through: the offer lists exactly the unseen versions, the install replaces
# the copy and starts the new one, and macOS did not stand in the way.
quit_app
start retry-after-failure $(feed good) || result retry-after-failure FAILED "did not start"
if wait_for $pid 'Install Update' 30; then
  shot offer
  windows_say $pid > "$out/offer.txt"
  notes=""
  grep -q PROBE-NEWEST "$out/offer.txt" || notes+="newest version missing; "
  grep -q PROBE-SKIPPED "$out/offer.txt" || notes+="skipped version missing; "
  # One grep line holds one paragraph of the window: the whole phrase means the bullet stayed whole.
  grep -q 'never installed, wrapped onto a second line' "$out/offer.txt" || notes+="a wrapped bullet broke in two; "
  grep -q PROBE-INSTALLED "$out/offer.txt" && notes+="the installed version shown; "
  grep -q -i 'Automatically download' "$out/offer.txt" && notes+="automatic install offered; "
  [[ -z $notes ]] && result changes-listed passed "the two unseen versions, not the installed one" \
    || result changes-listed FAILED "$notes"
  $ax press $pid "Install Update"
  relaunch_into retry-after-failure 0.9.2
else
  shot retry; result retry-after-failure FAILED "no offer"
fi
quit_app

no_write_access
