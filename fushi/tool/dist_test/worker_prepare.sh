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

# Dependencies: pub get + pub-cache patches + one tiny test run, which builds
# the native-asset hooks (sqlite3, pdfium download) while prepareEnv (proxy)
# is still set; the batches then run against the warm hook cache.
pub_key=$(git ls-files -s -- ':(glob)**/pubspec.yaml' ':(glob)**/pubspec.lock' \
  ci/patches ci/apply-patches.sh | git hash-object --stdin)
if [ "$(cat "$state/pub.key" 2>/dev/null || true)" != "$pub_key" ]; then
  echo "==> pub get"
  (cd fushi && flutter pub get --enforce-lockfile)
  echo "==> pub cache patches"
  bash ci/apply-patches.sh
  echo "==> warm native-asset hooks"
  (cd fushi && flutter test --no-pub test/tools/test_file_shards_test.dart > /dev/null)
  echo "$pub_key" > "$state/pub.key"
else
  echo "==> dependencies unchanged"
fi

# Rust test hard dependencies (same crate list as tool/bootstrap.sh and
# tool/native_libs.ps1), keyed by the crate's tree hash in this snapshot.
case "$(uname -s)" in
  Darwin) plat=macos; script=build_macos_dylib.sh ;;
  Linux) plat=linux-x64; script=build_linux_so.sh ;;
  *) echo "error: unsupported worker OS $(uname -s)" >&2; exit 3 ;;
esac
for crate in fushi_compute fushi_fsrs fushi_web_core fushi_rwkv; do
  key=$(git rev-parse "HEAD:native/$crate")
  stamp="$state/native-$crate.key"
  if [ "$(cat "$stamp" 2>/dev/null || true)" != "$key" ] ||
     [ -z "$(ls "native/$crate/prebuilt/$plat" 2>/dev/null)" ]; then
    echo "==> build native/$crate"
    bash "native/$crate/$script"
    echo "$key" > "$stamp"
  else
    echo "==> native/$crate unchanged"
  fi
done
echo "==> ready"
