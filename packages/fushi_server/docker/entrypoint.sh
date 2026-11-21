#!/bin/sh
# Container entrypoint for fushi_server.
#
# Runs as the image's non-root user (1000:1000) or whatever `user:` / `--user`
# sets (compose passes PUID:PGID from .env). Nothing here needs root, and the
# entrypoint never changes ownership: /config must already be writable by that
# user. First start writes /config/fushi_server.yaml with `fushi_server init`
# (data in /config/data, a fresh admin token printed to the log). Any arguments
# are a fushi_server command line (default: serve).
set -eu

CONFIG_DIR=/config
CONFIG="$CONFIG_DIR/fushi_server.yaml"

if [ ! -w "$CONFIG_DIR" ] || { [ -e "$CONFIG" ] && [ ! -w "$CONFIG" ]; }; then
  uid="$(id -u)"
  gid="$(id -g)"
  echo "fushi: $CONFIG_DIR is not writable by uid $uid (owner: $(stat -c %u:%g "$CONFIG_DIR"))." >&2
  echo "fushi: on the host, run: sudo chown -R $uid:$gid <your config folder>" >&2
  echo "fushi: or set PUID/PGID in .env to the folder's owner (id -u, id -g)." >&2
  exit 1
fi

cd "$CONFIG_DIR"
if [ ! -f "$CONFIG" ]; then
  # FUSHI_LANGUAGE (en | zh) only seeds `language:` in this first config.
  language=en
  case "${FUSHI_LANGUAGE:-}" in
    en | zh) language="$FUSHI_LANGUAGE" ;;
    '') ;;
    *) echo "fushi: ignoring FUSHI_LANGUAGE=$FUSHI_LANGUAGE (use en or zh)" >&2 ;;
  esac
  init_server() {
    /opt/fushi_server/bin/fushi_server init \
      --config "$CONFIG" \
      --data-dir "$CONFIG_DIR/data" \
      --device-name "${FUSHI_DEVICE_NAME:-Fushi Server}" "$@"
  }
  # The release-bundle image can package a server older than `init --language`
  # (Chinese-only builds). Those reject the option as unknown before writing
  # anything; only that exact error falls back to an init without it.
  # stdout (admin token, next steps) is held until we know which attempt counts,
  # so a rejected first attempt does not dump the usage text into the log.
  init_out="$(mktemp)"
  if init_err="$(init_server --language "$language" 2>&1 >"$init_out")"; then
    cat "$init_out"
    rm -f "$init_out"
    [ -z "$init_err" ] || echo "$init_err" >&2
  else
    rm -f "$init_out"
    case "$init_err" in
      # package:args: Could not find an option named "language" / "--language".
      *'option named "'*'language"'*)
        [ -z "${FUSHI_LANGUAGE:-}" ] \
          || echo "fushi: this server build has no language setting; FUSHI_LANGUAGE ignored" >&2
        init_server
        ;;
      *)
        echo "$init_err" >&2
        exit 1
        ;;
    esac
  fi
fi
# From here on the config (WebUI Settings) decides the language. Left set, the
# variable would keep overriding the CLI and logs while the WebUI follows the
# config, so the server never sees it.
unset FUSHI_LANGUAGE

[ "$#" -gt 0 ] || set -- serve
exec /opt/fushi_server/bin/fushi_server "$@"
