#!/bin/sh
# Container entrypoint for fushi_server.
#
# Started as root only to fix ownership of /config for PUID:PGID, then drops
# privileges for good (setpriv). First start writes /config/fushi_server.yaml
# with `fushi_server init` (data in /config/data, a fresh admin token printed
# to the log). Any arguments are a fushi_server command line (default: serve).
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CONFIG_DIR=/config
CONFIG="$CONFIG_DIR/fushi_server.yaml"

if [ "$(id -u)" = 0 ]; then
  mkdir -p "$CONFIG_DIR"
  # Only walk the tree when ownership is wrong (first start, or PUID changed);
  # media mounts are never touched.
  if [ "$(stat -c %u:%g "$CONFIG_DIR")" != "$PUID:$PGID" ]; then
    echo "fushi: chown -R $PUID:$PGID $CONFIG_DIR"
    chown -R "$PUID:$PGID" "$CONFIG_DIR"
  fi
  exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups -- "$0" "$@"
fi

cd "$CONFIG_DIR"
if [ ! -f "$CONFIG" ]; then
  /opt/fushi_server/bin/fushi_server init \
    --config "$CONFIG" \
    --data-dir "$CONFIG_DIR/data" \
    --device-name "${FUSHI_DEVICE_NAME:-Fushi Server}"
fi

[ "$#" -gt 0 ] || set -- serve
exec /opt/fushi_server/bin/fushi_server "$@"
