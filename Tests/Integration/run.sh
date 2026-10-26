#!/bin/bash
set -u

cd "$(dirname "$0")/../.."
swift build -c release --quiet || exit 1
worktape=$PWD/.build/release/worktape

work=$(mktemp -d "${TMPDIR:-/tmp}/worktape-integration.XXXXXX")
cleanup() {
  kill $(jobs -p) 2>/dev/null
  case $work in */worktape-integration.*) rm -rf "$work" ;; esac
}
trap cleanup EXIT

swiftc -O -o "$work/test-window" Tests/Integration/TestWindow.swift || exit 1
window=$work/test-window
mkdir "$work/project" "$work/zdotdir"
cd "$work/project" && "$worktape" init 2>/dev/null

long='for i in $(seq 1 400); do echo "line $i $RANDOM$RANDOM$RANDOM"; sleep 0.02; done; exit'
crashes_before=$(ls ~/Library/Logs/DiagnosticReports | grep -c '^worktape')
failures=0

type_into_session() {
  sleep 1.5
  for step in "$@"; do
    case $step in
      sleep:*) sleep "${step#sleep:}" ;;
      pause) printf '\034' ;;
      *) printf '%s\n' "$step" ;;
    esac
  done
  sleep 60
}

start() {
  name=$1
  shift
  sessions_before=$(ls .worktapes)
  type_into_session "$@" | ZDOTDIR=$work/zdotdir SHELL=/bin/zsh script -q /dev/null /bin/sh -c "stty cols 120 rows 40; exec \"$worktape\" record" > "$work/$name.log" 2>&1 &
  terminal=$!
  for _ in $(seq 50); do recorder=$(pgrep -P "$terminal") && break; sleep 0.1; done
}

child_named() {
  for _ in $(seq 600); do pgrep -P "$recorder" -x "$1" && return; sleep 0.02; done
}

expect() {
  name=$1
  expected=$2
  for _ in $(seq 300); do kill -0 "$recorder" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$recorder" 2>/dev/null; then
    echo "FAIL  $name: still running after 30 seconds"
    failures=$((failures + 1))
    kill -KILL $(pgrep -P "$recorder") "$recorder" "$terminal" 2>/dev/null
    return
  fi
  new_sessions=$(comm -13 <(echo "$sessions_before") <(ls .worktapes))
  if [ "$(echo "$new_sessions" | grep -c .)" != 1 ]; then
    echo "FAIL  $name: expected one new session, got: ${new_sessions:-none}"
    failures=$((failures + 1))
    kill "$terminal" 2>/dev/null
    return
  fi
  session=.worktapes/$new_sessions/
  actual="$(ls "$session" | grep -c '\.cast$') cast, $(ls "$session" | grep -c '\.mp4$') mp4, $(ls "$session" | grep -c '\.mov$') mov"
  unplayable=$(for video in "$session"*.mp4 "$session"*.mov; do
    [ -e "$video" ] && [ -z "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")" ] && basename "$video"
  done)
  if [ "$actual" = "$expected" ] && [ -z "$unplayable" ]; then
    echo "pass  $name"
  else
    echo "FAIL  $name: expected $expected, got $actual${unplayable:+, unplayable: $unplayable}"
    failures=$((failures + 1))
  fi
  kill "$terminal" 2>/dev/null
}

start exit "$window &" sleep:3 'kill %1' sleep:1 exit
expect exit "1 cast, 1 mp4, 1 mov"

start stop "$window &" sleep:3 "$worktape stop"
expect stop "1 cast, 1 mp4, 1 mov"

start pause "$window &" sleep:3 pause sleep:2 pause sleep:3 'kill %1' sleep:1 "$worktape stop"
expect pause "1 cast, 1 mp4, 2 mov"

start stubborn "trap '' HUP" "$worktape stop"
expect stubborn "1 cast, 1 mp4, 0 mov"

start orphaned "sh -c '$window &'" sleep:3 "pkill -f '$window'" sleep:1 exit
expect orphaned "1 cast, 1 mp4, 1 mov"

start terminate "$window"
sleep 5
kill -TERM "$recorder"
expect terminate "1 cast, 1 mp4, 1 mov"

start close "$window"
sleep 5
kill -KILL "$terminal"
expect close "1 cast, 1 mp4, 1 mov"

start interrupt-agg "$long"
kill -INT "$(child_named agg)"
expect interrupt-agg "1 cast, 0 mp4, 0 mov"

start interrupt-ffmpeg "$long"
kill -INT "$(child_named ffmpeg)"
expect interrupt-ffmpeg "1 cast, 0 mp4, 0 mov"

start terminate-render "$long"
child_named agg > /dev/null
kill -TERM "$recorder"
expect terminate-render "1 cast, 0 mp4, 0 mov"

start close-render "$long"
child_named agg > /dev/null
kill -KILL "$terminal"
expect close-render "1 cast, 1 mp4, 0 mov"

sleep 1
if [ "$(ls ~/Library/Logs/DiagnosticReports | grep -c '^worktape')" != "$crashes_before" ]; then
  echo "FAIL  worktape crashed, see ~/Library/Logs/DiagnosticReports"
  failures=$((failures + 1))
fi
if ls -d "${TMPDIR:-/tmp}"/worktape-[0-9A-F]* > /dev/null 2>&1; then
  echo "FAIL  temporary files left in ${TMPDIR:-/tmp}"
  failures=$((failures + 1))
fi
if pgrep -f "$work" > /dev/null; then
  echo "FAIL  processes left running"
  failures=$((failures + 1))
fi

[ "$failures" = 0 ] && echo "all passed" || echo "$failures failed"
exit "$failures"
