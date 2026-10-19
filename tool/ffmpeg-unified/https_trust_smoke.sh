#!/usr/bin/env bash
# Public-HTTPS trust smoke for a unified FFmpeg program (needs network).
#
# FFmpeg 8+ verifies TLS peers by default (tls_verify=1). Each platform must
# verify against a trust store that exists on the USER's device, not on the
# build machine: Android loads the system CA store (patch 0001), Apple asks the
# system trust store through Security.framework (patch 0004), Windows uses
# gnutls with the system store. A build that verifies against a missing store
# fails every public HTTPS handshake; a build that silently stopped verifying
# accepts anything. This checks both directions:
#
#   1. <trusted-url> (a real media file behind a publicly trusted certificate)
#      must open and demux with verification on;
#   2. every <untrusted-url> (self-signed / expired / wrong host) must be
#      REJECTED, and the error output must match <reject-pattern> - proving
#      the expected verifier ran (e.g. "System trust rejected" for patch 0004).
#
# Usage: https_trust_smoke.sh <ffmpeg> <trusted-url> <reject-pattern> <untrusted-url>...
# FFMPEG_HTTP_PROXY=http://host:port routes through an HTTP CONNECT proxy (TLS
# stays end-to-end, so verification is still exercised). Note that FFmpeg also
# honours the http_proxy environment variable on its own.
set -euo pipefail

FFMPEG="${1:?usage: https_trust_smoke.sh <ffmpeg> <trusted-url> <reject-pattern> <untrusted-url>...}"
GOOD="${2:?missing trusted url}"
PATTERN="${3:?missing reject pattern}"
shift 3
PROXY=()
if [ -n "${FFMPEG_HTTP_PROXY:-}" ]; then PROXY=(-http_proxy "$FFMPEG_HTTP_PROXY"); fi
[ "$#" -gt 0 ] || { echo "https_trust_smoke: give at least one untrusted url" >&2; exit 2; }

echo "[https-trust] trusted: $GOOD"
if ! "$FFMPEG" -hide_banner -loglevel warning -nostdin -tls_verify 1 ${PROXY[@]+"${PROXY[@]}"} \
    -i "$GOOD" -map 0 -c copy -f null - ; then
  echo "[https-trust] FAILED: a publicly trusted HTTPS source did not open with tls_verify=1" >&2
  exit 1
fi

for bad in "$@"; do
  echo "[https-trust] untrusted: $bad"
  log="$(mktemp)"
  status=0
  "$FFMPEG" -hide_banner -loglevel info -nostdin -tls_verify 1 ${PROXY[@]+"${PROXY[@]}"} \
    -i "$bad" -f null - >"$log" 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    cat "$log" >&2
    echo "[https-trust] FAILED: $bad was accepted - certificate verification is not enforced" >&2
    exit 1
  fi
  if ! grep -Eq "$PATTERN" "$log"; then
    cat "$log" >&2
    echo "[https-trust] FAILED: $bad was rejected, but not by the expected verifier ($PATTERN)" >&2
    exit 1
  fi
  rm -f "$log"
done
echo "[https-trust] PASS"
