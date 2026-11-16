#!/bin/sh
# /usr/local/bin/fushi_server: `docker compose exec fushi-server fushi_server ctl status`
# runs as the container's user (PUID:PGID), so the database and data files keep
# the right owner. Runs in /config so the default ./fushi_server.yaml is found.
set -eu
cd /config
# FUSHI_LANGUAGE from .env only seeds the first config (entrypoint.sh); the CLI
# follows the config's `language`, like the WebUI. One-off override:
#   docker compose exec fushi-server env FUSHI_CLI_LANGUAGE=zh fushi_server ctl status
unset FUSHI_LANGUAGE
if [ -n "${FUSHI_CLI_LANGUAGE:-}" ]; then
  export FUSHI_LANGUAGE="$FUSHI_CLI_LANGUAGE"
fi
exec /opt/fushi_server/bin/fushi_server "$@"
