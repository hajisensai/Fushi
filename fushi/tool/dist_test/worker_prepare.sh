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

# Dependencies: pub get + pub-cache patches + one tiny test run, which builds
# the native-asset hooks (sqlite3, pdfium download) while prepareEnv (proxy)
# is still set; the batches then run against the warm hook cache.
pub_key=$(git ls-files -s -- ':(glob)**/pubspec.yaml' ':(glob)**/pubspec.lock' \
  ci/patches ci/apply-patches.sh | git hash-object --stdin)
deps_changed=
if [ "$(cat "$state/pub.key" 2>/dev/null || true)" != "$pub_key" ]; then
  echo "==> pub get"
  (cd fushi && flutter pub get --enforce-lockfile)
  echo "==> pub cache patches"
  bash ci/apply-patches.sh
  deps_changed=1
else
  echo "==> dependencies unchanged"
fi
# fushi/lib/i18n/strings.g.dart is not tracked and `git clean` (no -x) keeps
# the previous snapshot's copy: regenerate on every prepare. gen_i18n.dart is
# stamped on the json / lockfile / SDK and the output's own hash, so an
# unchanged snapshot costs a hash, a changed one a fresh slang + format.
echo "==> i18n (fushi/tool/gen_i18n.dart)"
"$(dirname "$(command -v flutter)")/dart" fushi/tool/gen_i18n.dart
if [ -n "$deps_changed" ]; then
  echo "==> warm native-asset hooks"
  (cd fushi && flutter test --no-pub test/tools/test_file_shards_test.dart > /dev/null)
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
case "$(uname -s)" in
  Darwin) plat=macos; script=build_macos_dylib.sh ;;
  Linux) plat=linux-x64; script=build_linux_so.sh ;;
  MINGW*|MSYS*)
    # A Windows worker runs this under Git Bash; tool/native_libs.ps1 keeps
    # its own per-crate stamps (and copies from a sibling checkout, e.g. the
    # first slot, when the source tree matches).
    echo "==> native libraries (tool/native_libs.ps1)"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File tool/native_libs.ps1
    echo "==> ready (this script: ${SECONDS}s; the rest of the step is checkout and ssh)"
    exit 0 ;;
  *) echo "error: unsupported worker OS $(uname -s)" >&2; exit 3 ;;
esac
for crate in fushi_compute fushi_fsrs fushi_web_core fushi_rwkv; do
  key=$(git rev-parse "HEAD:native/$crate")
  stamp="$state/native-$crate.key"
  if [ "$(cat "$stamp" 2>/dev/null || true)" != "$key" ] ||
     [ -z "$(ls "native/$crate/prebuilt/$plat" 2>/dev/null)" ]; then
    # A secondary slot (DIST_NATIVE_PEER = the primary checkout, prepared
    # first) copies a library built from the same source tree.
    peer="${DIST_NATIVE_PEER:-}"
    if [ -n "$peer" ] &&
       [ "$(cat "$peer/.git/fushi-dist/native-$crate.key" 2>/dev/null || true)" = "$key" ] &&
       [ -n "$(ls "$peer/native/$crate/prebuilt/$plat" 2>/dev/null)" ]; then
      echo "==> copy native/$crate from $peer"
      mkdir -p "native/$crate/prebuilt"
      rm -rf "native/$crate/prebuilt/$plat"
      cp -R "$peer/native/$crate/prebuilt/$plat" "native/$crate/prebuilt/$plat"
    else
      echo "==> build native/$crate"
      bash "native/$crate/$script"
    fi
    echo "$key" > "$stamp"
  else
    echo "==> native/$crate unchanged"
  fi
done
echo "==> ready (this script: ${SECONDS}s; the rest of the step is checkout and ssh)"
