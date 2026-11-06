#!/usr/bin/env bash
# Runs inside fushi-linux-build image: Xvfb + app + dummy-data CLI scenario.
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq x11-apps imagemagick >/dev/null 2>&1
export APPDIR=/src/fushi/build/linux/x64/release/bundle DUMMY=/tmp/dummy SHOT_DIR=/out/shots
mkdir -p "$SHOT_DIR"
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
export DISPLAY=:99 WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
eval "$(dbus-launch --sh-syntax)"
export FUSHI_TEST_ROOT=/tmp/fushi-root FUSHI_CTL_DIR=/tmp/fushi-root/ctl; mkdir -p $FUSHI_TEST_ROOT
bash /scripts/make_dummy_data.sh > /out/dummy.log 2>&1
"$APPDIR/fushi" > /out/app.log 2>&1 &
APP=$!
for i in $(seq 1 60); do "$APPDIR/fushi_cli" status >/dev/null 2>&1 && break; sleep 1; done
bash /scripts/run_cli_smoke.sh  > /out/part1.log 2>&1
bash /scripts/run_cli_smoke2.sh > /out/part2.log 2>&1
kill -0 $APP 2>/dev/null && echo "app still alive" >> /out/part2.log || { wait $APP; echo "app exited rc=$?" >> /out/part2.log; }
"$APPDIR/fushi_cli" quit >/dev/null 2>&1; sleep 3; kill $APP 2>/dev/null
cp -r $FUSHI_TEST_ROOT /out/root-snapshot 2>/dev/null
