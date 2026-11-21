#!/bin/sh
# Docker HEALTHCHECK: the interconnect port answers GET /api/ping, the public
# probe clients use before pairing (/api/capabilities needs a paired token).
# TLS is on by default with a self-signed per-server certificate, so the
# certificate is not verified here; `tls: false` falls back to http.
port="${FUSHI_HEALTH_PORT:-38765}"
curl -fsSk --max-time 5 -o /dev/null "https://127.0.0.1:$port/api/ping" \
  || curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$port/api/ping"
