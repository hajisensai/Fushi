#!/usr/bin/env bash
# dist_test worker: run one batch.
#   bash fushi/tool/dist_test/worker_run.sh <concurrency|0> [flutter test args...]
#   bash fushi/tool/dist_test/worker_run.sh itest
# Test files arrive one per line on stdin; each must look like
# test/<...>_test.dart (integration_test/<...>_test.dart in itest mode) and
# exist, nothing else is accepted. stdout is the `flutter test --reporter json`
# event stream, the exit code is flutter's.
#
# Two options are this script's own, taken off before the runner starts
# (they reach it through any shim as plain `--name[=value]` options):
#   --fushi-package=<name>  the batch is packages/<name>'s suites; a pure Dart
#                           package (no Flutter SDK dependency) runs under
#                           `dart test`, as on CI.
#   --coverage              each runner process writes lcov to a file here,
#                           which then goes out on stdout as one
#                           {"type":"fushiCoverage","lcov":"<base64>"} line
#                           (the coordinator merges them; nothing else of
#                           this machine's files leaves it).
#
# itest mode (macOS only; Windows integration tests run on the coordinator's
# own machine through tool/run_windows_itest.ps1): the app is built once per
# checkout state from the generated entry (itest_entry.sh), then each file is
# one `flutter drive` launch of that binary, off-screen (FUSHI_TEST_HIDDEN),
# under a fresh data root (FUSHI_TEST_ROOT) so it never sees the owner's own
# Fushi data. stdout then carries one `{"type":"fushiItest",...}` line per
# file (exit code, wall time, base64 output tail), which the coordinator turns
# into events; drive's own output goes to stderr. worker_shim.sh only ever
# passes a number here, so this mode is out of reach through the shim.
set -uo pipefail
cd "$(dirname "$0")/../.."
state="$(cd .. && pwd)/.git/fushi-dist"
mkdir -p "$state"

concurrency=$1
shift
pkg=
coverage=
own=()
for a in "$@"; do
  case "$a" in
    --fushi-package=*) pkg=${a#--fushi-package=} ;;
    --coverage) coverage=1 ;;
    *) own+=("$a") ;;
  esac
done
set -- ${own[@]+"${own[@]}"}
itest=
if [ "$concurrency" = itest ]; then
  itest=1
  concurrency=0
  if [ "$(uname -s)" != Darwin ]; then
    echo "error: itest mode runs on macOS workers only" >&2
    exit 2
  fi
fi
case "$concurrency" in
  ''|*[!0-9]*) echo "error: bad concurrency '$concurrency'" >&2; exit 2 ;;
esac
path_re='^test/[A-Za-z0-9_./-]+_test\.dart$'
[ -n "$itest" ] && path_re='^integration_test/[A-Za-z0-9_./-]+_test\.dart$'
runner=flutter
if [ -n "$pkg" ]; then
  if [ -n "$itest" ] || ! printf '%s\n' "$pkg" | grep -Eq '^[a-z0-9_]+$' ||
     [ ! -f "../packages/$pkg/pubspec.yaml" ]; then
    echo "error: rejected package '$pkg'" >&2
    exit 2
  fi
  cd "../packages/$pkg" || exit 2
  grep -Eq '^[[:space:]]+sdk:[[:space:]]*flutter[[:space:]]*$' pubspec.yaml ||
    runner=dart
fi
if [ -n "$coverage" ] && { [ -n "$itest" ] || [ "$runner" = dart ]; }; then
  echo "error: --coverage is for flutter test batches only" >&2
  exit 2
fi

files=()
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  case "$f" in
    *..*) echo "error: rejected test path '$f'" >&2; exit 2 ;;
  esac
  if ! printf '%s\n' "$f" | grep -Eq "$path_re"; then
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

# Heartbeat of the checkout lock (see kDistLockStaleMinutes); fds detached
# so it can never hold the ssh channel open.
(while sleep 60; do touch "$state/lock"; done) > /dev/null 2>&1 < /dev/null &
heartbeat=$!
pid=
trap 'kill "$heartbeat" 2>/dev/null; [ -n "$pid" ] && kill_tree "$pid"; rm -f "$state/run.pid" "$state/runner.pid"; exit 143' TERM INT HUP
touch "$state/lock" 2>/dev/null

# worker_kill.sh stops this script (whose trap takes the test tree down) so
# no further chunk / file starts.
echo "$$" > "$state/runner.pid"

# Runs "$@" in the background as the killable child and waits for it.
run_child() {
  "$@" < /dev/null &
  pid=$!
  echo "$pid" > "$state/run.pid"
  wait "$pid"
}

rc=0
if [ -n "$itest" ]; then
  entry=integration_test/.dist/entry.dart
  app=build/macos/Build/Products/Debug/fushi.app
  log="$state/itest.log"
  mkdir -p "$(dirname "$entry")"
  bash tool/dist_test/itest_entry.sh > "$state/entry.new" || exit 2
  cmp -s "$state/entry.new" "$entry" || cp "$state/entry.new" "$entry"
  # Built once per checkout state: the prepared commit plus the entry.
  stamp="$(git rev-parse HEAD) $(cksum < "$entry")"
  built=
  if [ "$(cat "$state/itest-built" 2>/dev/null)" != "$stamp" ]; then
    rm -f "$state/itest-built"
    echo "== building $app" >&2
    run_child flutter build macos --debug --no-pub -t "$entry" > "$log" 2>&1
    status=$?
    cat "$log" >&2
    if [ "$status" -eq 0 ]; then
      echo "$stamp" > "$state/itest-built"
    else
      built="build failed (exit $status)"
    fi
  fi
  for f in "${files[@]}"; do
    start=$(date +%s)
    if [ -n "$built" ]; then
      status=1
    else
      root="$state/itest-root"
      rm -rf "$root" && mkdir -p "$root"
      echo "== $f" >&2
      FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ROOT="$root" \
        FUSHI_TEST_RUN_ID="dist-itest-$$" FUSHI_DIST_ITEST="$f" \
        run_child flutter drive --no-pub -d macos \
        --driver=test_driver/integration_test.dart -t "$entry" \
        "--use-application-binary=$app" > "$log" 2>&1
      status=$?
      cat "$log" >&2
    fi
    [ "$rc" -eq 0 ] && rc=$status
    # The app's progress lines (tests run / skipped) plus the end of output.
    tail=$({ grep -E '^(flutter: )?[0-9]+:[0-9]+ \+' "$log"; echo ...; tail -n 40 "$log"; } |
      base64 | tr -d '\n')
    printf '{"type":"fushiItest","path":"%s","exitCode":%d,"ms":%d,"tail":"%s"}\n' \
      "$f" "$status" "$(( ($(date +%s) - start) * 1000 ))" "$tail"
  done
else
  args=(test --reporter json)
  [ "$runner" = flutter ] && args+=(--no-pub)
  if [ "$concurrency" -gt 0 ]; then
    args+=("--concurrency=$concurrency")
  fi
  cov="$state/coverage.info"
  covarg=()
  if [ -n "$coverage" ]; then
    # flutter on Windows takes a Windows path.
    covpath=$cov
    [ -n "$windows" ] && covpath=$(cygpath -m "$cov")
    covarg=(--coverage "--coverage-path=$covpath")
  fi
  # Windows caps a command line at 32767 characters: a big batch runs as
  # several back-to-back processes, whose event streams the coordinator splits
  # again at each `start` event (as for its own local worker).
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
  for (( c = 0; c + 1 < ${#starts[@]}; c++ )); do
    from=${starts[$c]}
    count=$(( ${starts[$((c + 1))]} - from ))
    rm -f "$cov"
    run_child "$runner" "${args[@]}" ${covarg[@]+"${covarg[@]}"} "$@" \
      "${files[@]:$from:$count}"
    status=$?
    [ "$rc" -eq 0 ] && rc=$status
    if [ -n "$coverage" ] && [ -s "$cov" ]; then
      printf '{"type":"fushiCoverage","lcov":"'
      base64 < "$cov" | tr -d '\n'
      printf '"}\n'
    fi
  done
fi
kill "$heartbeat" 2>/dev/null
rm -f "$state/run.pid" "$state/runner.pid"
exit "$rc"
