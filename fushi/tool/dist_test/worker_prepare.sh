#!/usr/bin/env bash
# dist_test worker: get this checkout ready for `flutter test --no-pub`.
# Called by tool/dist_test.dart over ssh right after it checked out the run's
# snapshot (docs/specs/2026-10-24-distributed-unit-tests.md §2). Each step is
# keyed by a content hash under .git/fushi-dist/ and skipped when unchanged.
set -euo pipefail
cd "$(dirname "$0")/../../.."

want=$(sed -n 's/.*"flutter": *"\([^"]*\)".*/\1/p' fushi/.fvmrc)
have=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([^ ]*\).*/\1/p' | head -1)
if [ "$want" != "$have" ]; then
  echo "error: this worker runs Flutter '$have', fushi/.fvmrc pins '$want'" >&2
  exit 3
fi

state=.git/fushi-dist
mkdir -p "$state"
# Heartbeat of the checkout lock while native builds run (first build of a
# crate can take longer than the stale limit). Only while the lock exists: a
# coordinator that found no work left for this machine releases it and this
# prepare runs on to warm the caches; touching then would leave a plain file
# that blocks the next run's `mkdir` lock.
(while sleep 60; do [ ! -d "$state/lock" ] || touch "$state/lock"; done) \
  > /dev/null 2>&1 < /dev/null &
heartbeat=$!
# worker_kill.sh (run when the next coordinator takes the lock) waits for it.
echo "$$" > "$state/prepare.pid"
trap 'kill "$heartbeat" 2>/dev/null; rm -f "$state/prepare.pid"' EXIT

# Housekeeping of this checkout's objects here, not inside the next push:
# receive-pack's auto gc runs after the ref report and before the push
# returns, printing nothing, and the coordinator kills a push that is silent
# for two minutes (dist_workers.dart kDistPushStall). This script comes with
# the snapshot, so it also reaches workers whose shim predates that setting.
git config receive.autogc false
echo "==> git gc --auto"
git gc --auto --quiet || echo "warning: git gc --auto failed (exit $?)" >&2

# Dependencies: pub get + pub-cache patches + one tiny test run, which builds
# the native-asset hooks (sqlite3, pdfium download) while prepareEnv (proxy)
# is still set; the batches then run against the warm hook cache.
pub_key=$(git ls-files -s -- ':(glob)**/pubspec.yaml' ':(glob)**/pubspec.lock' \
  ci/patches ci/apply-patches.sh | git hash-object --stdin)
deps_changed=
if [ "$(cat "$state/pub.key" 2>/dev/null || true)" != "$pub_key" ]; then
  echo "==> pub get"
  (cd fushi && flutter pub get --enforce-lockfile)
  deps_changed=1
else
  echo "==> dependencies unchanged"
fi
# Every prepare, not only when this checkout's pub.key moved: the pub cache
# and the Flutter SDK are shared by every slot on this machine, so another
# slot's snapshot (a branch with a different patch set) may have changed them
# since this checkout last looked. The SDK step is stamped and a no-op when
# the SDK is already this snapshot's state; the pub-cache overlay is a copy.
echo "==> patches (pub cache + Flutter SDK)"
bash ci/apply-patches.sh
# fushi/lib/i18n/strings.g.dart is not tracked and `git clean` (no -x) keeps
# the previous snapshot's copy: regenerate on every prepare. gen_i18n.dart is
# stamped on the json / lockfile / SDK and the output's own hash, so an
# unchanged snapshot costs a hash, a changed one a fresh slang + format.
echo "==> i18n (fushi/tool/gen_i18n.dart)"
"$(dirname "$(command -v flutter)")/dart" fushi/tool/gen_i18n.dart
# The hook outputs under .dart_tool/hooks_runner are kept per hook input, so
# a checkout that goes back to dependencies it warmed before (two runs taking
# turns batch by batch, worker_slot.sh) finds them there: worker_cache.sh
# remembers which dependency keys were warmed and runs the test only for a
# new one.
if [ -n "$deps_changed" ]; then
  bash fushi/tool/dist_test/worker_cache.sh warm "$state" "$pub_key" \
    sh -c 'echo "==> warm native-asset hooks" &&
      cd fushi && flutter test --no-pub test/tools/test_file_shards_test.dart > /dev/null'
  echo "$pub_key" > "$state/pub.key"
fi

# Prebuilt third-party binaries are not in git (tool/vendored_binaries.json);
# many unit tests read them (libmpv archives, FFmpegKit AAR / xcframeworks,
# LunaHook, libplacebo). Files that already match cost one sha256 pass; misses
# come from the per-user cache shared by every slot on this machine, else the
# release (prepareEnv's proxy applies). Runs before the Windows early exit.
echo "==> vendored binaries"
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
  python3 tool/vendored_binaries.py fetch
else
  python tool/vendored_binaries.py fetch
fi

# Rust test hard dependencies (same crate list as tool/bootstrap.sh and
# tool/native_libs.ps1), keyed by the crate's tree hash in this snapshot.
#
# Same crate set as tool/native_libs.ps1 / tool/bootstrap.sh: a crate missing here
# leaves its dylib/so absent on mac/linux workers, and every test that loads it
# goes red only there (fushi_music → op_undo_music_test, fushi_corpus →
# library_corpus_service_test).
native_crates="fushi_compute fushi_fsrs fushi_web_core fushi_rwkv fushi_music fushi_corpus"
# fushi_fsrs is built with its test-only cargo feature `raw_sql` (the raw SQL
# channel that fushi_engine / fushi tests use to poke the database; release
# builds leave it out). The feature set is part of the key, so a library
# built without it (an older worker state) is rebuilt.
native_key() {
  features=""
  if [ "$1" = fushi_fsrs ]; then features=raw_sql; fi
  # The crate's tree hash, folded with the sources it pulls in from outside
  # native/<crate> (external_sources.txt): fushi_music compiles
  # native/fushi_compute/src/legacy_text.rs in (BUG-4988).
  key=$(bash tool/native_source_key.sh "$1")
  if [ -n "$features" ]; then key="$key+$features"; fi
}
# Each library set is kept under its key (worker_cache.sh): two runs that
# take turns on this checkout batch by batch (worker_slot.sh) with different
# crate trees copy their set back instead of building it on every turn.
case "$(uname -s)" in
  Darwin) plat=macos; script=build_macos_dylib.sh ;;
  Linux) plat=linux-x64; script=build_linux_so.sh ;;
  MINGW*|MSYS*)
    # A Windows worker runs this under Git Bash; tool/native_libs.ps1 keeps
    # its own per-crate stamps (and copies from a sibling checkout, e.g. the
    # first slot, when the source tree matches). This checkout's per-key
    # cache (worker_cache.sh) goes first: the library sets come back with
    # their stamps, and native_libs.ps1 then finds them current.
    plat=windows-x64
    for crate in $native_crates; do
      native_key "$crate"
      bash fushi/tool/dist_test/worker_cache.sh native-restore "$state" "$crate" "$key" "$plat" || true
    done
    echo "==> native libraries (tool/native_libs.ps1)"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File tool/native_libs.ps1
    for crate in $native_crates; do
      native_key "$crate"
      bash fushi/tool/dist_test/worker_cache.sh native-store "$state" "$crate" "$key" "$plat"
    done
    echo "==> ready (this script: ${SECONDS}s; the rest of the step is checkout and ssh)"
    exit 0 ;;
  *) echo "error: unsupported worker OS $(uname -s)" >&2; exit 3 ;;
esac
# Missing from this checkout's cache: a secondary slot (DIST_NATIVE_PEER = the
# primary checkout, prepared first) copies a set built from the same source
# tree, else the crate is built here.
for crate in $native_crates; do
  native_key "$crate"
  bash fushi/tool/dist_test/worker_cache.sh native "$state" "$crate" "$key" "$plat" \
    "${DIST_NATIVE_PEER:-}" \
    env FUSHI_FSRS_FEATURES="$features" bash -c \
    'echo "==> build native/$1${FUSHI_FSRS_FEATURES:+ (features $FUSHI_FSRS_FEATURES)}" &&
      bash "native/$1/$2"' build "$crate" "$script"
done
echo "==> ready (this script: ${SECONDS}s; the rest of the step is checkout and ssh)"
