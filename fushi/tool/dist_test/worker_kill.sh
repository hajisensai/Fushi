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
# The batch script first: its trap kills the test tree and it starts no
# further chunk.
runner=$(cat .git/fushi-dist/runner.pid 2>/dev/null || true)
case "$runner" in
  ''|*[!0-9]*) ;;
  *) kill -TERM "$runner" 2>/dev/null && sleep 1 ;;
esac
rm -f .git/fushi-dist/runner.pid
pidfile=.git/fushi-dist/run.pid
[ -f "$pidfile" ] || exit 0
pid=$(cat "$pidfile")
case "$pid" in
  ''|*[!0-9]*) rm -f "$pidfile"; exit 0 ;;
esac

kill_tree() {
  case "$(uname -s)" in
    MINGW*|MSYS*)
      # Git Bash: kill the Windows tree under the msys pid's Windows pid.
      local winpid
      winpid=$(cat "/proc/$1/winpid" 2>/dev/null) &&
        taskkill //F //T //PID "$winpid" > /dev/null 2>&1
      kill -TERM "$1" 2>/dev/null || true
      return ;;
  esac
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

kill_tree "$pid"
rm -f "$pidfile"
