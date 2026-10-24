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

kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

flutter "${args[@]}" "$@" "${files[@]}" < /dev/null &
pid=$!
echo "$pid" > "$state/run.pid"
# Heartbeat of the checkout lock (see kDistLockStaleMinutes); fds detached
# so it can never hold the ssh channel open.
(while sleep 60; do touch "$state/lock"; done) > /dev/null 2>&1 < /dev/null &
heartbeat=$!
trap 'kill "$heartbeat" 2>/dev/null; kill_tree "$pid"; rm -f "$state/run.pid"; exit 143' TERM INT HUP
touch "$state/lock" 2>/dev/null
wait "$pid"
rc=$?
kill "$heartbeat" 2>/dev/null
rm -f "$state/run.pid"
exit "$rc"
