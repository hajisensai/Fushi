#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 RUNTIME_DIRECTORY" >&2
  exit 64
fi

runtime_directory="$(cd "$1" && pwd)"
case "$(uname -m)" in
  arm64) java="$runtime_directory/runtime-macos-arm64/bin/java" ;;
  x86_64) java="$runtime_directory/runtime-macos-x64/bin/java" ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac
server="$runtime_directory/m-extension-server.jar"
for required in "$java" "$server" "$runtime_directory/checksums.json" \
  "$runtime_directory/LICENSE-M-Extension-Server.txt" \
  "$runtime_directory/NOTICE-M-Extension-Server.txt"; do
  if [[ ! -f "$required" ]]; then
    echo "missing bundled Mihon runtime asset: $required" >&2
    exit 1
  fi
done

port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
token="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
data_directory="$(mktemp -d "${TMPDIR:-/tmp}/hibiki-mihon-smoke.XXXXXX")"
stdout_log="$data_directory/server.out.log"
stderr_log="$data_directory/server.err.log"
pid=""

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf -- "$data_directory"
}
trap cleanup EXIT

FUSHI_MIHON_TOKEN="$token" "$java" -Xmx256m -Djava.awt.headless=true \
  -Djava.util.prefs.userRoot="$data_directory/preferences" \
  -jar "$server" "$port" "$data_directory" >"$stdout_log" 2>"$stderr_log" &
pid="$!"

base_url="http://127.0.0.1:$port"
ready=false
for _ in $(seq 1 100); do
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$stderr_log" >&2
    echo "bundled M-Extension-Server exited before becoming ready" >&2
    exit 1
  fi
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 1 -H "Authorization: Bearer $token" \
    "$base_url/capabilities" || true)"
  if [[ "$status" == "200" ]]; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  cat "$stderr_log" >&2
  echo "bundled M-Extension-Server did not become ready" >&2
  exit 1
fi

capabilities="$(curl --fail --silent --show-error --max-time 2 \
  -H "Authorization: Bearer $token" "$base_url/capabilities")"
python3 - "$capabilities" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
required = {
    "hibikiMihonBridge": 1,
    "sourceFactory": True,
    "preferenceCallbacks": True,
    "imageProxy": True,
    "sourceUrls": True,
}
if any(value.get(key) != expected for key, expected in required.items()):
    raise SystemExit(f"incompatible Mihon capabilities: {value!r}")
PY

for route in / /capabilities /dalvik /inspect /source-image \
  /source-data/clear /image/unauthorized /stop; do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 2 "$base_url$route" || true)"
  if [[ "$status" != "401" ]]; then
    echo "unauthenticated $route returned $status, expected 401" >&2
    exit 1
  fi
done

lan_address="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -n "$lan_address" ]]; then
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 1 --max-time 1 "http://$lan_address:$port/capabilities" || true)"
  if [[ "$status" != "000" ]]; then
    echo "M-Extension-Server was reachable through non-loopback $lan_address" >&2
    exit 1
  fi
fi

curl --fail --silent --show-error --max-time 2 -X POST \
  -H "Authorization: Bearer $token" "$base_url/stop" >/dev/null
for _ in $(seq 1 50); do
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid"
    pid=""
    echo "desktop runtime smoke passed"
    exit 0
  fi
  sleep 0.1
done
echo "M-Extension-Server process remained after authenticated stop" >&2
exit 1
