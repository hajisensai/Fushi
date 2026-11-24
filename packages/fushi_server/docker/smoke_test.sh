#!/usr/bin/env bash
# Smoke-test a fushi_server image: first-start init as a non-root --user, health
# check, /api/ping, admin API, bundled tools. Used by server-docker.yml (PR CI)
# and release-server.yml's docker job (before any push), and by hand:
#
#   bash packages/fushi_server/docker/smoke_test.sh <image> [--language en|zh]
#
# --language: also start with FUSHI_LANGUAGE=<l> and check the first config has
# `language: <l>` and the WebUI login page is served in it. Leave it out for
# images that package a server older than the language setting.
#
# Host ports default to 38765/38780; set SMOKE_SYNC_PORT / SMOKE_WEBUI_PORT when
# those are taken (e.g. a Fushi app on the same machine).
set -euo pipefail

image="${1:?usage: smoke_test.sh <image> [--language en|zh]}"
shift
language=""
if [[ "${1:-}" = "--language" ]]; then
  language="${2:?--language needs en or zh}"
fi
sync_port="${SMOKE_SYNC_PORT:-38765}"
webui_port="${SMOKE_WEBUI_PORT:-38780}"
name="fushi-smoke-$$"

fail() {
  echo "::error::$*"
  exit 1
}

cfg="$(mktemp -d)"
# The container runs as 1234:1234, like PUID/PGID in compose; let it write here.
chmod 777 "$cfg"
cfg_mount="$cfg"
# Git Bash on Windows: hand docker.exe a C:/ path and stop MSYS from rewriting
# in-container paths such as /config/fushi_server.yaml.
if command -v cygpath >/dev/null 2>&1; then
  cfg_mount="$(cygpath -m "$cfg")"
  export MSYS_NO_PATHCONV=1
fi
lang_env=()
[[ -z "$language" ]] || lang_env=(-e "FUSHI_LANGUAGE=$language")
docker run -d --name "$name" --user 1234:1234 "${lang_env[@]}" \
  -v "$cfg_mount:/config" -p "$sync_port:38765" -p "$webui_port:38780" "$image" >/dev/null
cleanup() {
  docker logs "$name" 2>&1 | tail -n 40 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  # Files in $cfg belong to uid 1234; remove them from inside a container.
  docker run --rm --user 1234:1234 -v "$cfg_mount:/c" --entrypoint sh "$image" -c 'rm -rf /c/* /c/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$cfg" 2>/dev/null || true
}
trap cleanup EXIT

health=starting
for _ in $(seq 1 60); do
  health="$(docker inspect -f '{{.State.Health.Status}}' "$name")"
  [[ "$health" = healthy ]] && break
  [[ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]] || break
  sleep 3
done
[[ "$health" = healthy ]] || fail "container not healthy ($health)"

docker exec "$name" test -f /config/fushi_server.yaml || fail "first start did not write the config"
owner="$(docker exec "$name" stat -c %u:%g /config/fushi_server.yaml)"
[[ "$owner" = 1234:1234 ]] || fail "config owned by $owner, expected 1234:1234"
pid1_uid="$(docker exec "$name" sh -c 'stat -c %u /proc/1')"
[[ "$pid1_uid" = 1234 ]] || fail "server runs as uid $pid1_uid, expected 1234"
image_user="$(docker inspect -f '{{.Config.User}}' "$image")"
case "$image_user" in '' | 0 | 0:* | root | root:*) fail "image default user is root ($image_user)" ;; *) ;; esac

ping="$(curl -fsSk "https://127.0.0.1:$sync_port/api/ping")"
case "$ping" in *'"app":"fushi"'*) ;; *) fail "unexpected /api/ping: $ping" ;; esac

token="$(docker exec "$name" sed -n 's/^admin_token: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /config/fushi_server.yaml)"
[[ -n "$token" ]] || fail "no admin_token in the first config"
status="$(curl -fsSk -H "Authorization: Bearer $token" "https://127.0.0.1:$webui_port/api/admin/status")"
case "$status" in *'"dataDir":"/config/data"'*) ;; *) fail "unexpected admin status: $status" ;; esac

docker exec "$name" sh -c 'command -v ffmpeg && command -v ffprobe && command -v 7z' >/dev/null \
  || fail "ffmpeg / ffprobe / 7z missing"

if [[ -n "$language" ]]; then
  docker exec "$name" grep -Eq "^language: \"?$language\"?\$" /config/fushi_server.yaml \
    || fail "first config does not have language: $language"
  html_lang=en
  [[ "$language" = zh ]] && html_lang=zh-CN
  login="$(curl -fsSk "https://127.0.0.1:$webui_port/")"
  case "$login" in *"<html lang=\"$html_lang\">"*) ;; *) fail "WebUI login page is not lang=$html_lang" ;; esac
  # The server process must not keep FUSHI_LANGUAGE (WebUI Settings decide later).
  if docker exec "$name" sh -c 'tr "\0" "\n" < /proc/1/environ' | grep -q '^FUSHI_LANGUAGE='; then
    fail "FUSHI_LANGUAGE is still set for the server process"
  fi
fi

echo "smoke ok: $image${language:+ (language $language)}"
