#!/usr/bin/env bash
# Floating lyric window evidence on Linux (run build_in_docker.sh first, so the
# source volume is synced and the build caches are warm):
#   bash tool/linux/floating_lyric_itest_in_docker.sh
#     -> build/linux-dist/floating-lyric/{itest.log,ready.png,passthrough.png,
#        xwininfo-*.txt,flyric-*.png}
# Runs integration_test/linux_floating_lyric_itest.dart under Xvfb + D-Bus with
# FUSHI_TEST_FLOATING_LYRIC=1, and while the test holds the window up it takes
# an X screenshot and xwininfo of the window (override-redirect state, geometry).
set -euo pipefail
# `pwd -W` gives C:/... on Git Bash: docker.exe cannot read /c/... paths (MSYS_NO_PATHCONV is on).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && { pwd -W 2>/dev/null || pwd; })"
export MSYS_NO_PATHCONV=1
OUT="$ROOT/build/linux-dist/floating-lyric"
mkdir -p "$OUT"
cores="$(nproc 2>/dev/null || echo 8)"
docker run --rm -i \
  --cpus "${FUSHI_DOCKER_CPUS:-$(( cores > 2 ? cores / 2 : 1 ))}" \
  --memory "${FUSHI_DOCKER_MEMORY:-12g}" \
  -v fushi-linux-src:/src -v fushi-linux-pub:/root/.pub-cache \
  -v fushi-linux-cache:/root/.cache -v "$OUT:/out" \
  fushi-linux-build:trixie bash -s <<'IN'
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq x11-apps x11-utils imagemagick >/dev/null 2>&1
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:99 FUSHI_TEST_FLOATING_LYRIC=1 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
mkdir -p /tmp/fushi-root
export FUSHI_TEST_ROOT=/tmp/fushi-root
cd /src/fushi
# Compiler shims (clang -> gcc-14) come with the image.
dbus-run-session -- flutter test integration_test/linux_floating_lyric_itest.dart \
  -d linux --no-pub > /out/itest.log 2>&1 &
TEST=$!
shot() {  # $1 = marker in the log, $2 = name
  for _ in $(seq 1 2400); do
    grep -q "$1" /out/itest.log 2>/dev/null && break
    kill -0 "$TEST" 2>/dev/null || return 0
    sleep 0.5
  done
  sleep 1
  xid="$(grep -o "$1 [^ ]* *xid=[0-9]*" /out/itest.log | grep -o 'xid=[0-9]*' | tail -1 | cut -d= -f2)"
  xwd -root -silent | convert xwd:- "/out/$2.png"
  [ -n "$xid" ] && [ "$xid" != 0 ] && xwininfo -id "$xid" > "/out/xwininfo-$2.txt" 2>&1
  xwininfo -root -tree > "/out/tree-$2.txt" 2>&1
}
shot '\[flyric\] READY' ready
shot '\[flyric\] PASSTHROUGH' passthrough
wait "$TEST"; echo "exit=$?" >> /out/itest.log
cp /tmp/flyric-*.png /out/ 2>/dev/null || true
kill "$XVFB" 2>/dev/null || true
IN
grep -E '\[flyric\]|All tests passed|Some tests failed|exit=' "$OUT/itest.log" | tail -20
