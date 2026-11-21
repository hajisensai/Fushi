#!/usr/bin/env bash
# dist_test worker: who has a checkout, one batch at a time (2026-11-15).
#
# A checkout used to belong to one run from its `lock` to its `finish`: a
# full-suite run kept every slot of the Mac for its whole length, and a
# 7-second run of another session was turned away (59% of 281 asks) and went
# back to the requester's own machine. Now:
#
#   take <checkout> <runId> <waitSeconds>
#       Queues for the checkout and takes its lock when this run is the
#       oldest one waiting and the lock is free. Waits up to <waitSeconds>
#       (0: one look), then exit 75 `busy: ...`; the ticket stays, so asking
#       again keeps the place in the queue.
#   yield <checkout> <runId>
#       After a batch: gives the lock up when another run waits (prints
#       `yielded`; the run's ref stays, it queues again with `take`), else
#       keeps it (`kept`). `lost` when the lock is no longer this run's.
#   drop <checkout> <runId>
#       The run is over here: ticket, ref and lock (if it is this run's) go.
#
# State, all under <checkout>/.git/fushi-dist/:
#   lock/owner       the run that has the checkout; the directory's mtime is
#                    the heartbeat (worker_run.sh), stale after 15 min
#   queue/<runId>    a waiting run: the content is when it queued (epoch
#                    seconds, kept across asks), the mtime its last sign of
#                    life. Only a ticket touched within the last PRESENT
#                    seconds counts (its run is asking right now); one silent
#                    for TICKET_STALE seconds is removed.
#
# Reached over stdin (`bash -s -- take ...`) on a trusted machine and as
# ~/.fushi-worker/slot.sh behind the shim, so it reads nothing from the
# checkout and its arguments are checked here.
set -uo pipefail

EX_BUSY=75
EX_REFUSED=2
LOCK_STALE_MIN=15
PRESENT=20
TICKET_STALE=90
MAX_WAIT=120

die() { echo "error: $*" >&2; exit "$EX_REFUSED"; }

verb=${1:-}
dir=${2:-}
run=${3:-}
[ -n "$dir" ] && [ -d "$dir/.git" ] || die "no checkout at '$dir'"
printf '%s\n' "$run" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$' ||
  die "bad run id '$run'"
cd "$dir" || die "cannot enter $dir"
state=.git/fushi-dist
queue=$state/queue
ticket=$queue/$run
mkdir -p "$queue" || die "cannot create $queue"

now() { date +%s; }

# GNU stat (Linux, Git Bash) first: BSD stat's -f means something else there.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

owner() { cat "$state/lock/owner" 2>/dev/null; }

# The runs asking right now, oldest first, one `<queued-at> <runId>` a line.
waiting() {
  local f t age at
  t=$(now)
  for f in "$queue"/*; do
    [ -f "$f" ] || continue
    age=$(( t - $(mtime "$f") ))
    if [ "$age" -gt "$TICKET_STALE" ]; then
      rm -f "$f"
      continue
    fi
    [ "$age" -le "$PRESENT" ] || continue
    at=$(cat "$f" 2>/dev/null)
    case "$at" in ''|*[!0-9]*) at=0 ;; esac
    echo "$at ${f##*/}"
  done | sort -k1,1n -k2,2
}

# A new ticket: queued now, and always after every ticket already there (the
# clock has whole seconds; a run that gave the checkout up and asks again
# within the same second must not sort ahead of the one it gave it to).
enqueue() {
  local at last=0 f v
  at=$(now)
  for f in "$queue"/*; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -lt "$last" ] || last=$v
  done
  [ "$at" -gt "$last" ] || at=$(( last + 1 ))
  echo "$at" > "$ticket"
}

try_lock() {
  mkdir "$state/lock" 2>/dev/null && return 0
  [ "$(owner)" = "$run" ] && return 0
  if [ -n "$(find "$state/lock" -maxdepth 0 -mmin +$LOCK_STALE_MIN 2>/dev/null)" ]; then
    rm -rf "$state/lock" && mkdir "$state/lock" 2>/dev/null && return 0
  fi
  return 1
}

cmd_take() {
  local wait=${1:-0}
  case "$wait" in ''|*[!0-9]*) die "bad wait '$wait'" ;; esac
  [ "$wait" -le "$MAX_WAIT" ] || wait=$MAX_WAIT
  local deadline=$(( $(now) + wait )) first
  # Queued at the first ask; a later ask finds the ticket and keeps its place.
  [ -f "$ticket" ] || enqueue
  while :; do
    # Dropped meanwhile (the requester gave this worker up): stop asking.
    [ -f "$ticket" ] || { echo "busy: this run gave the checkout up" >&2; exit "$EX_BUSY"; }
    touch "$ticket"
    first=$(waiting | head -1 | cut -d' ' -f2)
    if [ "$first" = "$run" ] && try_lock; then
      echo "$run" > "$state/lock/owner"
      # A drop that came between the look above and the lock: give it back.
      if [ ! -f "$ticket" ]; then
        rm -rf "$state/lock"
        echo "busy: this run gave the checkout up" >&2
        exit "$EX_BUSY"
      fi
      rm -f "$ticket"
      # Leftover batch processes are only killed once the lock is ours:
      # before that they may be another live run's.
      if [ -f fushi/tool/dist_test/worker_kill.sh ]; then
        bash fushi/tool/dist_test/worker_kill.sh
      fi
      echo "locked $dir"
      exit 0
    fi
    [ "$(now)" -lt "$deadline" ] || break
    sleep 1
  done
  local ahead
  ahead=$(waiting | grep -vc " $run\$")
  echo "busy: in use by dist_test run $(owner) ($ahead other run(s) waiting)" >&2
  exit "$EX_BUSY"
}

cmd_yield() {
  if [ "$(owner)" != "$run" ]; then
    echo lost
    exit 0
  fi
  if [ -n "$(waiting | grep -v " $run\$" | head -1)" ]; then
    rm -rf "$state/lock"
    echo yielded
  else
    touch -c "$state/lock"
    echo kept
  fi
}

cmd_drop() {
  rm -f "$ticket"
  git update-ref -d "refs/dist/$run" 2>/dev/null
  if [ "$(owner)" = "$run" ]; then
    rm -rf "$state/lock"
  fi
  exit 0
}

case "$verb" in
  take) cmd_take "${4:-0}" ;;
  yield) cmd_yield ;;
  drop) cmd_drop ;;
  *) die "usage: worker_slot.sh take|yield|drop <checkout> <runId> [waitSeconds]" ;;
esac
