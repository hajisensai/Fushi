#!/bin/sh
# /usr/local/bin/fushi_server: `docker compose exec fushi-server fushi_server status`
# runs as root by default; drop to PUID:PGID so the database and data files keep
# the right owner. Runs in /config so the default ./fushi_server.yaml is found.
set -eu
cd /config
if [ "$(id -u)" = 0 ]; then
  exec setpriv --reuid="${PUID:-1000}" --regid="${PGID:-1000}" --clear-groups -- \
    /opt/fushi_server/bin/fushi_server "$@"
fi
exec /opt/fushi_server/bin/fushi_server "$@"
