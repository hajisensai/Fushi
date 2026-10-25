#!/usr/bin/env bash
# dist_test worker: run one batch.
#   bash fushi/tool/dist_test/worker_run.sh <concurrency|0> [flutter test args...]
# Test files arrive one per line on stdin; each must look like
# test/<...>_test.dart and exist, nothing else is accepted. stdout is the
# `flutter test --reporter json` event stream, the exit code is flutter's.
set -uo pipefail
cd "$(dirname "$0")/../.."
state="$(cd .. && pwd)/.git/fushi-dist"
mkdir -p "$state"

concurrency=$1
shift
case "$concurrency" in
  ''|*[!0-9]*) echo "error: bad concurrency '$concurrency'" >&2; exit 2 ;;
esac

files=()
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  case "$f" in
    *..*) echo "error: rejected test path '$f'" >&2; exit 2 ;;
  esac
  if ! printf '%s\n' "$f" | grep -Eq '^test/[A-Za-z0-9_./-]+_test\.dart$'; then
    echo "error: rejected test path '$f'" >&2
    exit 2
  fi
  if [ ! -f "$f" ]; then
    echo "error: no such test file '$f'" >&2
    exit 2
  fi
  files+=("$f")
done
if [ "${#files[@]}" -eq 0 ]; then
  echo "error: empty batch" >&2
  exit 2
fi

args=(test --no-pub --reporter json)
if [ "$concurrency" -gt 0 ]; then
  args+=("--concurrency=$concurrency")
fi

windows=
case "$(uname -s)" in MINGW*|MSYS*) windows=1 ;; esac

kill_tree() {
  if [ -n "$windows" ]; then
    # Git Bash: $! is an msys pid; the Windows tree (dart, flutter_tester)
    # hangs off its Windows pid.
    local winpid
    winpid=$(cat "/proc/$1/winpid" 2>/dev/null) &&
      taskkill //F //T //PID "$winpid" > /dev/null 2>&1
    kill -TERM "$1" 2>/dev/null || true
    return
  fi
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

# Windows caps a command line at 32767 characters: a big batch runs as several
# back-to-back processes, whose event streams the coordinator splits again at
# each `start` event (as for its own local worker).
max_chars=0
[ -n "$windows" ] && max_chars=24000
# Start index of each chunk in files (plain arrays: macOS ships bash 3.2).
starts=(0)
len=0
for i in "${!files[@]}"; do
  f=${files[$i]}
  if [ "$max_chars" -gt 0 ] && [ "$len" -gt 0 ] &&
     [ $(( len + ${#f} + 1 )) -gt "$max_chars" ]; then
    starts+=("$i")
    len=0
  fi
  len=$(( len + ${#f} + 1 ))
done
starts+=("${#files[@]}")

# Heartbeat of the checkout lock (see kDistLockStaleMinutes); fds detached
# so it can never hold the ssh channel open.
(while sleep 60; do touch "$state/lock"; done) > /dev/null 2>&1 < /dev/null &
heartbeat=$!
pid=
trap 'kill "$heartbeat" 2>/dev/null; [ -n "$pid" ] && kill_tree "$pid"; rm -f "$state/run.pid" "$state/runner.pid"; exit 143' TERM INT HUP
touch "$state/lock" 2>/dev/null

# worker_kill.sh stops this script (whose trap takes the test tree down) so
# no further chunk starts.
echo "$$" > "$state/runner.pid"
rc=0
for (( c = 0; c + 1 < ${#starts[@]}; c++ )); do
  from=${starts[$c]}
  count=$(( ${starts[$((c + 1))]} - from ))
  flutter "${args[@]}" "$@" "${files[@]:$from:$count}" < /dev/null &
  pid=$!
  echo "$pid" > "$state/run.pid"
  wait "$pid"
  status=$?
  [ "$rc" -eq 0 ] && rc=$status
done
kill "$heartbeat" 2>/dev/null
rm -f "$state/run.pid" "$state/runner.pid"
exit "$rc"
