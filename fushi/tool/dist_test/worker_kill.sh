#!/usr/bin/env bash
# dist_test worker: stop the batch worker_run.sh is running (timeout, Ctrl-C
# on the coordinator, or a leftover from a dropped connection). Only the
# process tree recorded in .git/fushi-dist/run.pid is touched.
set -uo pipefail
cd "$(dirname "$0")/../../.."
pidfile=.git/fushi-dist/run.pid
[ -f "$pidfile" ] || exit 0
pid=$(cat "$pidfile")
case "$pid" in
  ''|*[!0-9]*) rm -f "$pidfile"; exit 0 ;;
esac

kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

kill_tree "$pid"
rm -f "$pidfile"
