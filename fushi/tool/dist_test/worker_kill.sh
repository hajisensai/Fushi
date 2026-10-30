#!/usr/bin/env bash
# dist_test worker: stop the batch worker_run.sh is running (timeout, Ctrl-C
# on the coordinator, or a leftover from a dropped connection). Only the
# process tree recorded in .git/fushi-dist/run.pid is touched.
set -uo pipefail
cd "$(dirname "$0")/../../.."
# A prepare an earlier coordinator stopped waiting for (no work was left for
# this machine) runs on to warm the caches: wait for it instead of checking a
# new commit out under it. At most 30 minutes, keeping the new lock fresh.
prep=$(cat .git/fushi-dist/prepare.pid 2>/dev/null || true)
case "$prep" in
  ''|*[!0-9]*) ;;
  *)
    waited=0
    while kill -0 "$prep" 2>/dev/null && [ "$waited" -lt 1800 ]; do
      [ ! -d .git/fushi-dist/lock ] || touch .git/fushi-dist/lock
      sleep 5
      waited=$((waited + 5))
    done ;;
esac
# Both pid files are read before anything is signalled: the batch script's
# trap removes run.pid on its way out.
pids=
for f in runner.pid run.pid; do
  p=$(cat ".git/fushi-dist/$f" 2>/dev/null || true)
  case "$p" in
    ''|*[!0-9]*) ;;
    *) pids="$pids $p" ;;
  esac
done
rm -f .git/fushi-dist/runner.pid .git/fushi-dist/run.pid
[ -n "$pids" ] || exit 0

case "$(uname -s)" in
  MINGW*|MSYS*)
    # Git Bash: taskkill /F /T ends the Windows tree under each msys pid at
    # once (the batch script first, so it starts no further chunk).
    for p in $pids; do
      winpid=$(cat "/proc/$p/winpid" 2>/dev/null) &&
        taskkill //F //T //PID "$winpid" > /dev/null 2>&1
      kill -TERM "$p" 2>/dev/null || true
    done
    exit 0 ;;
esac

# Every process of both trees, gathered before the first signal (a parent
# that dies hands its children to init, out of reach of pgrep -P).
tree() {
  local child
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    tree "$child"
  done
}
victims=$(for p in $pids; do tree "$p"; done | sort -u)
# shellcheck disable=SC2086 # one pid per word
kill -TERM $victims 2>/dev/null
# TERM is not enough: the flutter tool handles it in Dart, and with
# --coverage it merges the VM's report in one synchronous loop that runs for
# minutes at 100% CPU, so the handler only gets its turn after that. Seen
# 2026-10-30: a timed-out batch's flutter tool outlived the kill by 30 min.
waited=0
while [ "$waited" -lt 10 ]; do
  alive=
  for v in $victims; do
    kill -0 "$v" 2>/dev/null && alive=1
  done
  [ -n "$alive" ] || exit 0
  sleep 1
  waited=$((waited + 1))
done
# shellcheck disable=SC2086
kill -KILL $victims 2>/dev/null
exit 0
