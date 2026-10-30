#!/usr/bin/env bash
# dist_test worker: `flutter analyze` of this checkout, for tool/heavy.dart's
# offload (tool/dist_test.dart --analyze).
#   bash fushi/tool/dist_test/worker_analyze.sh [--[no-]fatal-infos] [--[no-]fatal-warnings]
# Paths arrive one per line on stdin (none: the whole app); each must lie under
# lib/ test/ tool/ integration_test/ test_driver/ or bin/ and exist, nothing
# else is accepted. stdout and the exit code are flutter analyze's.
set -uo pipefail
cd "$(dirname "$0")/../.."
state="$(cd .. && pwd)/.git/fushi-dist"
mkdir -p "$state"

for a in "$@"; do
  case "$a" in
    --fatal-infos|--no-fatal-infos|--fatal-warnings|--no-fatal-warnings) ;;
    *) echo "error: rejected analyze option '$a'" >&2; exit 2 ;;
  esac
done

path_re='^(lib|test|tool|integration_test|test_driver|bin)(/[A-Za-z0-9_.-]+)*/?$'
paths=()
while IFS= read -r f || [ -n "$f" ]; do
  f=${f%$'\r'}
  [ -z "$f" ] && continue
  case "$f" in
    *..*) echo "error: rejected path '$f'" >&2; exit 2 ;;
  esac
  if ! printf '%s\n' "$f" | grep -Eq "$path_re"; then
    echo "error: rejected path '$f'" >&2
    exit 2
  fi
  if [ ! -e "$f" ]; then
    echo "error: no such path '$f'" >&2
    exit 2
  fi
  paths+=("$f")
done

# Heartbeat of the checkout lock and the pid files worker_kill.sh reads, as in
# worker_run.sh.
(while sleep 60; do touch "$state/lock"; done) > /dev/null 2>&1 < /dev/null &
heartbeat=$!
pid=
trap 'kill "$heartbeat" 2>/dev/null; [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null; rm -f "$state/run.pid" "$state/runner.pid"; exit 143' TERM INT HUP
touch "$state/lock" 2>/dev/null
echo "$$" > "$state/runner.pid"

flutter analyze --no-pub "$@" ${paths[@]+"${paths[@]}"} < /dev/null &
pid=$!
echo "$pid" > "$state/run.pid"
wait "$pid"
rc=$?
kill "$heartbeat" 2>/dev/null
rm -f "$state/run.pid" "$state/runner.pid"
exit "$rc"
