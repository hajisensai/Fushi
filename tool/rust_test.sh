#!/usr/bin/env bash
# Run a native Rust crate's tests in the local dev loop: build once with the
# `quick` profile, then spread the tests over several PROCESSES.
#
#   bash tool/rust_test.sh <crate> [options] [name filter...] [-- <libtest args>]
#
#   bash tool/rust_test.sh fushi_fsrs                      # everything
#   bash tool/rust_test.sh fushi_fsrs sync2::tests_causal  # names containing any filter
#   bash tool/rust_test.sh fushi_fsrs --features id_audit
#   bash tool/rust_test.sh fushi_rwkv -- --nocapture
#
# Options:
#   --features <list>   passed to cargo
#   --profile <name>    cargo profile (default: quick, see /.cargo/config.toml)
#   --jobs <n>          number of processes (default: 3/4 of the logical cores)
#
# Why processes and not `cargo test`'s threads: fushi_fsrs's tests do not scale
# inside one process. Measured 2026-11-11 (i5-12600KF, 384 tests): `cargo test`
# with 16 threads takes 207 s, the same binary split over 12 processes 85 s; a
# 16-test subset takes 7 s on one thread and 11-18 s on 16. Separate processes
# scale almost linearly (8 processes do 8x the work in 1.3x the time). What
# serialises the threads is not known yet (ruled out: SQLite's shared page
# cache, the Rust allocator), so this goes around it instead of waiting for it.
#
# What runs: the crate's unit tests and tests/*.rs (cargo `--tests`); doctests
# do not. CI keeps running `cargo test --release --locked` (native-*-gate.yml);
# this script is for the local loop only. Exit status is 0 only when every
# process passed AND the number of tests reported equals the number selected.
set -euo pipefail

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

[ $# -ge 1 ] || usage
crate="$1"
shift
profile=quick
features=""
jobs=""
filters=()
libtest_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --features) features="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --) shift; libtest_args=("$@"); break ;;
    -h | --help) usage ;;
    -*) echo "rust_test: unknown option $1" >&2; usage ;;
    *) filters+=("$1"); shift ;;
  esac
done

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root/native/$crate" 2>/dev/null || {
  echo "rust_test: no crate at native/$crate" >&2
  exit 64
}
# cargo sets this for the tests it runs; tests that read it at run time expect it.
CARGO_MANIFEST_DIR="$(pwd -W 2>/dev/null || pwd)"
export CARGO_MANIFEST_DIR

if [ -z "$jobs" ]; then
  cores="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  jobs=$((cores * 3 / 4))
  [ "$jobs" -ge 1 ] || jobs=1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cargo_args=(test --profile "$profile" --locked --tests --no-run --message-format=json-render-diagnostics)
[ -z "$features" ] || cargo_args+=(--features "$features")
echo "== cargo ${cargo_args[*]}  (native/$crate)"
cargo "${cargo_args[@]}" > "$work/build.json"

# Test executables: JSON paths come with escaped backslashes on Windows.
sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' "$work/build.json" | sed 's/\\\\/\//g' > "$work/exes.txt"
if [ ! -s "$work/exes.txt" ]; then
  echo "rust_test: cargo produced no test executable for native/$crate" >&2
  exit 1
fi

# One line per test: "<executable index>\t<test name>", filtered, sorted so that
# neighbouring (usually similar-cost) tests land in different processes.
: > "$work/tests.txt"
n=0
while IFS= read -r exe; do
  n=$((n + 1))
  "$exe" --list 2>/dev/null | tr -d '\r' | sed -n 's/: test$//p' | while IFS= read -r name; do
    if [ "${#filters[@]}" -gt 0 ]; then
      hit=0
      for f in "${filters[@]}"; do
        case "$name" in *"$f"*) hit=1 ;; esac
      done
      [ "$hit" -eq 1 ] || continue
    fi
    printf '%s\t%s\n' "$n" "$name"
  done >> "$work/tests.txt"
done < "$work/exes.txt"
sort -o "$work/tests.txt" "$work/tests.txt"
total="$(wc -l < "$work/tests.txt" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
  echo "rust_test: no test matches ${filters[*]:-<no filter>}" >&2
  exit 1
fi
[ "$jobs" -le "$total" ] || jobs="$total"
awk -v n="$jobs" -v d="$work" '{ print > (d "/shard_" (NR % n) ".txt") }' "$work/tests.txt"

# Runs one process per (shard, executable); a long name list is cut into several
# invocations to stay under the Windows command-line limit.
run_shard() {
  local i="$1" exe_index=0 exe name rc=0
  while IFS= read -r exe; do
    exe_index=$((exe_index + 1))
    local names=() chars=0
    while IFS= read -r name; do
      names+=("$name")
      chars=$((chars + ${#name} + 1))
      if [ "$chars" -gt 20000 ]; then
        "$exe" --exact "${names[@]}" --test-threads=1 ${libtest_args[@]+"${libtest_args[@]}"} >> "$work/shard_$i.log" 2>&1 || rc=1
        names=()
        chars=0
      fi
    done < <(awk -F '\t' -v e="$exe_index" '$1 == e { print $2 }' "$work/shard_$i.txt")
    if [ "${#names[@]}" -gt 0 ]; then
      "$exe" --exact "${names[@]}" --test-threads=1 ${libtest_args[@]+"${libtest_args[@]}"} >> "$work/shard_$i.log" 2>&1 || rc=1
    fi
  done < "$work/exes.txt"
  return "$rc"
}

echo "== $total tests in $jobs processes"
started=$SECONDS
pids=()
for i in $(seq 0 $((jobs - 1))); do
  run_shard "$i" &
  pids+=("$!")
done
failed_shards=0
for pid in "${pids[@]}"; do
  wait "$pid" || failed_shards=$((failed_shards + 1))
done

sum() {
  cat "$work"/shard_*.log | sed -n 's/^test result: .*/&/p' | grep -oE "[0-9]+ $1" | awk '{ s += $1 } END { print s + 0 }'
}
passed="$(sum passed)"
failed="$(sum failed)"
ignored="$(sum ignored)"

if [ "${#libtest_args[@]}" -gt 0 ]; then
  # --nocapture and friends: the caller asked for the output.
  cat "$work"/shard_*.log
elif [ "$failed_shards" -gt 0 ]; then
  for log in "$work"/shard_*.log; do
    if grep -qE '^test result: FAILED|^error|panicked' "$log"; then
      sed -n '/^failures:/,$p' "$log"
      grep -q '^failures:' "$log" || tail -n 40 "$log"
    fi
  done
fi

echo "== $passed passed; $failed failed; $ignored ignored; $((SECONDS - started)) s (native/$crate, $jobs processes)"
if [ "$failed_shards" -gt 0 ] || [ "$failed" -gt 0 ]; then
  exit 1
fi
if [ $((passed + failed + ignored)) -ne "$total" ]; then
  echo "rust_test: $total tests selected but $((passed + failed + ignored)) reported, treat as failed" >&2
  exit 1
fi
