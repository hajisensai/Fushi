#!/usr/bin/env bash
# Headless smoke run of the built Linux bundle inside the build image:
# Xvfb + a D-Bus session, isolated FUSHI_TEST_ROOT, screenshot after N seconds.
#   bash tool/linux/smoke_in_docker.sh [seconds]   -> build/linux-dist/smoke/{run.log,screen.png}
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECS="${1:-45}"
export MSYS_NO_PATHCONV=1
mkdir -p "$ROOT/build/linux-dist/smoke"
docker run --rm -i -v fushi-linux-src:/src -v "$ROOT/build/linux-dist/smoke:/out" \
  -e SECS="$SECS" fushi-linux-build:trixie bash -s <<'IN'
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq x11-apps imagemagick >/dev/null 2>&1
B=/src/fushi/build/linux/x64/release/bundle
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:99
# Containers have no user namespaces for WPE's bubblewrap sandbox (build.md: container tests only).
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
mkdir -p /tmp/fushi-root
dbus-run-session -- bash -c "FUSHI_TEST_ROOT=/tmp/fushi-root timeout $SECS $B/fushi > /out/run.log 2>&1; echo exit=\$? >> /out/run.log" &
APP=$!
sleep $((SECS - 5))
xwd -root -silent | convert xwd:- /out/screen.png
wait "$APP"
kill "$XVFB" 2>/dev/null || true
IN
tail -5 "$ROOT/build/linux-dist/smoke/run.log"
