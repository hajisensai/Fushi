#!/usr/bin/env bash
# dist_test worker shim: the only thing a dist_test key may run on a machine
# that is not yours (docs/specs/2026-10-24-distributed-unit-tests.md §7.2).
#
# The machine's owner installs it once (worker_setup.sh / worker_setup.ps1
# copy it to ~/.fushi-worker/shim) and pins the key to it in authorized_keys:
#
#   restrict,command="bash ~/.fushi-worker/shim" ssh-ed25519 AAAA... fushi-dist
#
# sshd then runs this script for every connection with the client's command in
# SSH_ORIGINAL_COMMAND, whatever the client asked for. Only these are accepted,
# every argument checked against a fixed pattern:
#
#   hello                              platform, Flutter, cores, memory, pause
#   lock <slot> <runId>                take checkout <slot> for one run
#   git-receive-pack '<work|work-N>'   receive the run's snapshot commit
#   prepare <slot> <sha>               check it out, pub get, native libraries
#   run <slot> <concurrency> [args]    one batch; test files on stdin
#   analyze <slot> [--[no-]fatal-*]    flutter analyze; paths on stdin
#   kill <slot>                        stop that slot's batch / analyze
#   finish <slot> <runId>              drop the run's ref and lock
#
# Anything else is refused. Nothing outside $FUSHI_WORKER_HOME is written by
# the shim itself; the tests it runs are the requester's code (that part is
# trust between friends, see the spec), run as this account.
#
# Run by hand (no SSH_ORIGINAL_COMMAND) it is the owner's switch:
#   bash ~/.fushi-worker/shim pause    # refuse new work (a running batch is
#                                      # killed with `kill`, or just let it end)
#   bash ~/.fushi-worker/shim resume
#   bash ~/.fushi-worker/shim status
#
# Owner settings, all optional, in ~/.fushi-worker/limits (KEY=number lines):
#   MAX_SLOTS          checkouts / parallel flutter test processes (default 1)
#   MAX_CONCURRENCY    cap on flutter test --concurrency (default cores / 2)
#   MIN_FREE_MEM_MB    refuse a batch below this much free memory (4096)
#   MIN_FREE_DISK_GB   refuse a run below this much free disk (20)
# ~/.fushi-worker/path (one directory per line: Flutter's bin, cargo's bin;
# sshd's non-interactive shell does not read the login profile), and
# ~/.fushi-worker/prepare.env (KEY=value lines) for the prepare step only,
# e.g. HTTPS_PROXY for pub / cargo downloads. The requester can set none of
# them.
set -uo pipefail

W="${FUSHI_WORKER_HOME:-$HOME/.fushi-worker}"
EX_BUSY=75
EX_REFUSED=2

if [ -f "$W/path" ]; then
  while IFS= read -r p || [ -n "$p" ]; do
    p=${p%$'\r'}
    case "$p" in ''|'#'*|*:*) continue ;; esac
    [ -d "$p" ] && PATH="$p:$PATH"
  done < "$W/path"
  export PATH
fi

die() { echo "error: $*" >&2; exit "$EX_REFUSED"; }
busy() { echo "busy: $*" >&2; exit "$EX_BUSY"; }

os_kind() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

cores() {
  case "$(os_kind)" in
    macos) sysctl -n hw.ncpu ;;
    windows) echo "${NUMBER_OF_PROCESSORS:-$(nproc)}" ;;
    *) nproc ;;
  esac
}

free_mem_mb() {
  case "$(os_kind)" in
    macos)
      vm_stat | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
        /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); n += $NF }
        END { printf "%d\n", n * ps / 1048576 }' ;;
    linux) awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo ;;
    # Git Bash's /proc/meminfo, filled by the msys runtime from the kernel's
    # performance counters: MemFree is Windows' available memory (the same
    # number as FreePhysicalMemory). Not WMI: under sshd a standard account
    # is denied Get-CimInstance, which read as 0 and turned every batch busy.
    windows) awk '/^MemFree:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo ;;
    *) echo 0 ;;
  esac
}

free_disk_gb() {
  mkdir -p "$W"
  df -Pk "$W" | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'
}

# KEY=number lines only; anything else in the file is ignored, never executed.
limit() {
  local key=$1 default=$2 v=
  if [ -f "$W/limits" ]; then
    v=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\$/\1/p" \
      "$W/limits" | tail -1)
  fi
  echo "${v:-$default}"
}

max_slots() { limit MAX_SLOTS 1; }
max_concurrency() {
  local c
  c=$(cores)
  limit MAX_CONCURRENCY $(( c / 2 > 0 ? c / 2 : 1 ))
}

paused() { [ -e "$W/pause" ]; }

slot_dir() {
  case "$1" in
    1) echo "$W/work" ;;
    *) echo "$W/work-$1" ;;
  esac
}

check_slot() {
  case "$1" in
    ''|*[!0-9]*) die "bad slot '$1'" ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le "$(max_slots)" ] ||
    die "slot $1 not offered (MAX_SLOTS=$(max_slots))"
}

check_run_id() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$' ||
    die "bad run id '$1'"
}

# The lock this run took in `lock`; every later step needs it.
check_owner() {
  [ "$(cat "$1/.git/fushi-dist/lock/owner" 2>/dev/null)" != "" ] ||
    die "slot is not locked; call lock first"
}

# flutter test options the requester may pass: --name or --name=value with a
# plain value, or a plain value after one (`--exclude-tags golden`). No paths,
# no quoting, no shell characters.
check_flutter_arg() {
  printf '%s\n' "$1" | grep -Eq '^(--[a-z][a-z-]*(=[A-Za-z0-9_,.:+-]*)?|[A-Za-z0-9_,.:+][A-Za-z0-9_,.:+-]*)$' ||
    die "rejected flutter test argument '$1'"
}

STALE_MIN=15

cmd_hello() {
  echo "os=$(os_kind)"
  echo "flutter=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([^ ]*\).*/\1/p' | head -1)"
  echo "cores=$(cores)"
  echo "free_mem_mb=$(free_mem_mb)"
  echo "free_disk_gb=$(free_disk_gb)"
  echo "max_slots=$(max_slots)"
  echo "max_concurrency=$(max_concurrency)"
  echo "paused=$(paused && echo yes || echo no)"
  echo "analyze=yes"
}

cmd_lock() {
  [ $# -eq 2 ] || die "usage: lock <slot> <runId>"
  check_slot "$1"
  check_run_id "$2"
  paused && busy "paused by the owner"
  local disk need
  disk=$(free_disk_gb)
  need=$(limit MIN_FREE_DISK_GB 20)
  [ "$disk" -ge "$need" ] || busy "only ${disk} GB free disk (MIN_FREE_DISK_GB=$need)"
  local dir
  dir=$(slot_dir "$1")
  mkdir -p "$dir" && cd "$dir" || die "cannot create $dir"
  [ -d .git ] || git init -q || die "git init failed"
  # Pack and build paths under a Windows profile pass MAX_PATH easily.
  [ "$(os_kind)" = windows ] && git config core.longpaths true
  # Borrow objects so a push only carries what is new: secondary slots from
  # the first checkout, the first one from the owner's seed clone
  # (worker_setup clones the public repo there), if any.
  local borrow=
  if [ "$1" != 1 ]; then
    borrow="$W/work/.git/objects"
  elif [ -d "$W/seed/.git/objects" ]; then
    borrow="$W/seed/.git/objects"
  elif [ -d "$W/seed/objects" ]; then
    borrow="$W/seed/objects"
  fi
  if [ -n "$borrow" ] && [ -d "$borrow" ] &&
     [ ! -s .git/objects/info/alternates ]; then
    if [ "$(os_kind)" = windows ]; then
      cygpath -m "$borrow" > .git/objects/info/alternates
    else
      echo "$borrow" > .git/objects/info/alternates
    fi
  fi
  mkdir -p .git/fushi-dist
  if ! mkdir .git/fushi-dist/lock 2>/dev/null; then
    if [ -n "$(find .git/fushi-dist/lock -maxdepth 0 -mmin +$STALE_MIN)" ]; then
      rm -rf .git/fushi-dist/lock && mkdir .git/fushi-dist/lock ||
        busy "lock race"
    else
      busy "in use by dist_test run $(cat .git/fushi-dist/lock/owner 2>/dev/null)"
    fi
  fi
  echo "$2" > .git/fushi-dist/lock/owner
  if [ -f fushi/tool/dist_test/worker_kill.sh ]; then
    bash fushi/tool/dist_test/worker_kill.sh
  fi
  echo "locked $dir"
}

cmd_receive() {
  # git push sends: git-receive-pack 'work' (or 'work-N').
  local rel
  rel=$(printf '%s\n' "$1" | sed -n "s/^git-receive-pack '\(work\(-[0-9]\)\{0,1\}\)'\$/\1/p")
  [ -n "$rel" ] || die "rejected: $1"
  local slot=1
  case "$rel" in work-*) slot=${rel#work-} ;; esac
  check_slot "$slot"
  local dir
  dir=$(slot_dir "$slot")
  check_owner "$dir"
  exec git receive-pack "$dir"
}

cmd_prepare() {
  [ $# -eq 2 ] || die "usage: prepare <slot> <sha>"
  check_slot "$1"
  printf '%s\n' "$2" | grep -Eq '^[0-9a-f]{40}$' || die "bad commit '$2'"
  local dir
  dir=$(slot_dir "$1")
  check_owner "$dir"
  cd "$dir" || die "no checkout"
  git checkout -q --detach --force "$2" || die "checkout $2 failed"
  git clean -qfd -e 'native/*/prebuilt/' -e 'native/*/target/'
  local -a env=()
  if [ -f "$W/prepare.env" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%$'\r'}
      if printf '%s\n' "$line" | grep -Eq '^[A-Z_][A-Z0-9_]*=.*$'; then
        env+=("$line")
      fi
    done < "$W/prepare.env"
  fi
  [ "$1" != 1 ] && env+=("DIST_NATIVE_PEER=$W/work")
  # Output to a file, printed afterwards: a daemon left behind by pub / cargo
  # would inherit the ssh channel and keep the connection open forever.
  env ${env[@]+"${env[@]}"} bash fushi/tool/dist_test/worker_prepare.sh \
    > .git/fushi-dist-prepare.log 2>&1 < /dev/null
  local rc=$?
  cat .git/fushi-dist-prepare.log
  exit "$rc"
}

cmd_run() {
  [ $# -ge 2 ] || die "usage: run <slot> <concurrency> [flutter test args]"
  check_slot "$1"
  local dir
  dir=$(slot_dir "$1")
  check_owner "$dir"
  shift
  local concurrency=$1
  shift
  case "$concurrency" in ''|*[!0-9]*) die "bad concurrency '$concurrency'" ;; esac
  local cap
  cap=$(max_concurrency)
  if [ "$concurrency" -eq 0 ] || [ "$concurrency" -gt "$cap" ]; then
    concurrency=$cap
  fi
  local a
  for a in "$@"; do check_flutter_arg "$a"; done
  paused && busy "paused by the owner"
  local mem need
  mem=$(free_mem_mb)
  need=$(limit MIN_FREE_MEM_MB 4096)
  [ "$mem" -ge "$need" ] || busy "low memory: ${mem} MB free (MIN_FREE_MEM_MB=$need)"
  cd "$dir" || die "no checkout"
  # worker_run.sh reads the test files from stdin and accepts only
  # test/<...>_test.dart paths that exist in this checkout.
  exec bash fushi/tool/dist_test/worker_run.sh "$concurrency" "$@"
}

cmd_analyze() {
  [ $# -ge 1 ] || die "usage: analyze <slot> [--[no-]fatal-infos|--[no-]fatal-warnings]"
  check_slot "$1"
  local dir
  dir=$(slot_dir "$1")
  check_owner "$dir"
  shift
  local a
  for a in "$@"; do
    case "$a" in
      --fatal-infos|--no-fatal-infos|--fatal-warnings|--no-fatal-warnings) ;;
      *) die "rejected analyze option '$a'" ;;
    esac
  done
  paused && busy "paused by the owner"
  local mem need
  mem=$(free_mem_mb)
  need=$(limit MIN_FREE_MEM_MB 4096)
  [ "$mem" -ge "$need" ] || busy "low memory: ${mem} MB free (MIN_FREE_MEM_MB=$need)"
  cd "$dir" || die "no checkout"
  # worker_analyze.sh reads the paths from stdin and accepts only existing
  # lib/ test/ tool/ ... paths of this checkout.
  exec bash fushi/tool/dist_test/worker_analyze.sh "$@"
}

cmd_kill() {
  [ $# -eq 1 ] || die "usage: kill <slot>"
  check_slot "$1"
  local dir
  dir=$(slot_dir "$1")
  [ -f "$dir/fushi/tool/dist_test/worker_kill.sh" ] || exit 0
  cd "$dir" && exec bash fushi/tool/dist_test/worker_kill.sh
}

cmd_finish() {
  [ $# -eq 2 ] || die "usage: finish <slot> <runId>"
  check_slot "$1"
  check_run_id "$2"
  local dir
  dir=$(slot_dir "$1")
  cd "$dir" 2>/dev/null || exit 0
  git update-ref -d "refs/dist/$2" 2>/dev/null
  if [ "$(cat .git/fushi-dist/lock/owner 2>/dev/null)" = "$2" ]; then
    rm -rf .git/fushi-dist/lock
  fi
  exit 0
}

if [ -z "${SSH_ORIGINAL_COMMAND+x}" ]; then
  mkdir -p "$W"
  case "${1:-}" in
    pause) touch "$W/pause"; echo "paused: new dist_test work is refused" ;;
    resume) rm -f "$W/pause"; echo "resumed" ;;
    status) cmd_hello ;;
    *) echo "usage: bash $0 pause|resume|status" >&2; exit "$EX_REFUSED" ;;
  esac
  exit 0
fi

request=$SSH_ORIGINAL_COMMAND
case "$request" in
  git-receive-pack\ *) cmd_receive "$request" ;;
esac
# Plain words only: no quotes, globs or shell syntax reach any command.
printf '%s\n' "$request" | grep -Eq '^[A-Za-z0-9_ ,.:=+-]+$' ||
  die "rejected request"
read -r -a words <<< "$request"
verb=${words[0]:-}
args=("${words[@]:1}")
case "$verb" in
  hello) cmd_hello ;;
  lock) cmd_lock ${args[@]+"${args[@]}"} ;;
  prepare) cmd_prepare ${args[@]+"${args[@]}"} ;;
  run) cmd_run ${args[@]+"${args[@]}"} ;;
  analyze) cmd_analyze ${args[@]+"${args[@]}"} ;;
  kill) cmd_kill ${args[@]+"${args[@]}"} ;;
  finish) cmd_finish ${args[@]+"${args[@]}"} ;;
  *) die "not allowed: $verb" ;;
esac
