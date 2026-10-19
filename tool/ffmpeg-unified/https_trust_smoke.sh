#!/usr/bin/env bash
# HTTPS trust smoke for a unified FFmpeg program.
#
# FFmpeg 8+ verifies TLS peers by default (tls_verify=1). Each platform must
# verify against a trust store that exists on the USER's device, not on the
# build machine: Android loads the system CA store (patch 0001), Apple asks the
# system trust store through Security.framework (patch 0004), Windows uses
# gnutls with the system store. A build that verifies against a missing store
# fails every public HTTPS handshake; a build that silently stopped verifying
# accepts anything. Both directions are checked:
#
# Negative cases - hermetic: certificates are generated here and served by
# `openssl s_server` on 127.0.0.1 (random ports); no external site is used.
#   A. self-signed leaf, system trust (no ca_file): must be rejected, and the
#      error output must match <reject-pattern> - proving the expected verifier
#      ran (e.g. "System trust rejected the certificate" for patch 0004).
#   B. leaf signed by a local test CA, wrong subjectAltName, -ca_file <CA>:
#      must be rejected (host name binding).
#   C. leaf signed by the local CA, expired, -ca_file <CA>: must be rejected.
#   D. control: leaf signed by the local CA, valid, right name, -ca_file <CA>:
#      must OPEN - otherwise B / C failing would prove nothing about the
#      checks they target.
#
# Positive case - needs a real public CA chain, so it needs the network:
#   E. <trusted-url> (default: a fixed file at a fixed commit on
#      raw.githubusercontent.com) must open with tls_verify=1 through the
#      system trust store. To tell "network unreachable" from "verification
#      failed", the same URL is first fetched with tls_verify=0: if that fails
#      the script reports NETWORK UNREACHABLE and exits 3 (a failure, never a
#      pass); only a URL that opens without verification and fails with it is
#      reported as a trust failure (exit 1).
#
# Usage: https_trust_smoke.sh <ffmpeg> <reject-pattern> [<trusted-url>]
#   FFMPEG_HTTP_PROXY=http://host:port  route case E through an HTTP CONNECT
#     proxy (TLS stays end-to-end, so verification is still exercised). FFmpeg
#     also honours the http_proxy environment variable on its own; the local
#     cases always pass -http_proxy "" so they never leave 127.0.0.1.
# Exit: 0 pass, 1 verification defect, 2 usage / test setup error,
#       3 network unreachable for the positive case.
# Requires the `openssl` command line tool (OpenSSL or LibreSSL).
set -euo pipefail

FFMPEG="${1:?usage: https_trust_smoke.sh <ffmpeg> <reject-pattern> [<trusted-url>]}"
PATTERN="${2:?usage: https_trust_smoke.sh <ffmpeg> <reject-pattern> [<trusted-url>]}"
# A fixed blob at a fixed commit: the content can never change or disappear
# with a branch, and raw.githubusercontent.com serves it with a public chain.
GOOD="${3:-https://raw.githubusercontent.com/hajisensai/Fushi/8cc94d6d60b743d12ff7030841e0f2e9fe3a9486/tool/bluray/tests/dovi-p5.mkv}"

command -v openssl >/dev/null 2>&1 ||
  { echo "[https-trust] SETUP: openssl command not found (needed for the local TLS servers)" >&2; exit 2; }

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  local status=$?
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" >/dev/null 2>&1 || true; done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  # Leave WORK first: Windows cannot delete the current directory. Cleanup must
  # never change the verdict (exit codes 1 / 2 / 3 mean different things).
  cd / && rm -rf "$WORK" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

# MSYS (Git bash) rewrites "/CN=..." arguments into Windows paths unless told not to.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

ossl() {
  if ! openssl "$@" >"$WORK/openssl.log" 2>&1; then
    cat "$WORK/openssl.log" >&2
    echo "[https-trust] SETUP: openssl $1 failed" >&2
    exit 2
  fi
}

# --- certificates -------------------------------------------------------------
cd "$WORK"
cat >ext.cnf <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = fushi-https-smoke
[ ca_ext ]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[ leaf_ok ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
[ leaf_wrong ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:wrong.host.invalid
EOF

# Local test CA (trusted only through -ca_file, never by the system).
ossl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 \
  -config ext.cnf -extensions ca_ext -subj "/CN=Fushi HTTPS smoke test CA"
# A: self-signed leaf with the right name - untrusted only because of its issuer.
ossl req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.pem -days 2 \
  -config ext.cnf -extensions leaf_ok -subj "/CN=127.0.0.1"

sign_leaf() { # <name> <extensions> [<startdate> <enddate>]
  ossl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -config ext.cnf -subj "/CN=127.0.0.1"
  if [ "$#" -eq 2 ]; then
    ossl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial \
      -days 2 -extfile ext.cnf -extensions "$2" -out "$1.pem"
    return
  fi
  # Backdated validity: `openssl ca` takes explicit start / end dates on both
  # OpenSSL and LibreSSL (x509 -req cannot backdate portably).
  mkdir -p "ca-$1"
  : >"ca-$1/index.txt"
  echo 1000 >"ca-$1/serial"
  cat >"ca-$1.cnf" <<EOF
[ ca ]
default_ca = test_ca
[ test_ca ]
dir = ca-$1
database = \$dir/index.txt
serial = \$dir/serial
new_certs_dir = \$dir
certificate = ca.pem
private_key = ca.key
default_md = sha256
policy = any
unique_subject = no
copy_extensions = none
[ any ]
commonName = supplied
EOF
  ossl ca -batch -config "ca-$1.cnf" -in "$1.csr" -out "$1.pem" \
    -startdate "$3" -enddate "$4" -extfile ext.cnf -extensions "$2"
}
sign_leaf ok leaf_ok                                  # D
sign_leaf wrong leaf_wrong                            # B
sign_leaf expired leaf_ok 200101000000Z 200102000000Z   # C

printf '1\n00:00:00,000 --> 00:00:01,000\nfushi https smoke\n\n' >cue.srt

# --- local servers ------------------------------------------------------------
start_server() { # <cert-name> -> sets PORT
  local tries=0
  while :; do
    PORT=$((20000 + RANDOM % 30000))
    (exec openssl s_server -quiet -accept "$PORT" -cert "$1.pem" -key "$1.key" -WWW) \
      >"server-$1.log" 2>&1 &
    PIDS+=("$!")
    local pid="$!" waited=0
    # Ready when the port accepts a TCP connection; give up on a dead server.
    while [ "$waited" -lt 100 ]; do
      if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then return 0; fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      waited=$((waited + 1))
    done
    kill "$pid" >/dev/null 2>&1 || true
    tries=$((tries + 1))
    if [ "$tries" -ge 5 ]; then
      cat "server-$1.log" >&2
      echo "[https-trust] SETUP: openssl s_server for $1 did not come up" >&2
      exit 2
    fi
  done
}

fetch_local() { # <port> <log> [extra ffmpeg input options...] ; returns ffmpeg status
  local port="$1" log="$2"
  shift 2
  local status=0
  "$FFMPEG" -hide_banner -loglevel info -nostdin -y -http_proxy "" -tls_verify 1 "$@" \
    -i "https://127.0.0.1:$port/cue.srt" -f srt out.srt >"$log" 2>&1 || status=$?
  return "$status"
}

expect_rejected() { # <case> <port> <pattern> [ffmpeg options...]
  local name="$1" port="$2" pattern="$3"
  shift 3
  echo "[https-trust] $name"
  if fetch_local "$port" "$WORK/case.log" "$@"; then
    cat "$WORK/case.log" >&2
    echo "[https-trust] FAILED: $name was accepted - certificate verification is not enforced" >&2
    exit 1
  fi
  if ! grep -Eq "$pattern" "$WORK/case.log"; then
    cat "$WORK/case.log" >&2
    echo "[https-trust] FAILED: $name was rejected, but not by the expected verifier ($pattern)" >&2
    exit 1
  fi
  # Show why it was rejected (the TLS layer's own message), for the CI log.
  grep -m1 -E '^\[tls' "$WORK/case.log" | sed 's/^/    /' || true
}

start_server self;    PORT_SELF=$PORT
start_server ok;      PORT_OK=$PORT
start_server wrong;   PORT_WRONG=$PORT
start_server expired; PORT_EXPIRED=$PORT

# D first: if the control does not open, B / C would fail for the wrong reason.
echo "[https-trust] D. control: local CA, valid, right name (-ca_file)"
if ! fetch_local "$PORT_OK" "$WORK/case.log" -ca_file ca.pem ||
    ! grep -q 'fushi https smoke' "$WORK/out.srt"; then
  cat "$WORK/case.log" >&2
  echo "[https-trust] SETUP: the valid local certificate did not open - the negative cases would prove nothing" >&2
  exit 2
fi
expect_rejected "A. self-signed, system trust" "$PORT_SELF" "$PATTERN"
# B / C: any failure counts once D proved the same setup opens; ffmpeg's own
# wording differs per TLS backend (OpenSSL / gnutls).
expect_rejected "B. wrong host name (-ca_file)" "$PORT_WRONG" '.' -ca_file ca.pem
expect_rejected "C. expired (-ca_file)" "$PORT_EXPIRED" '.' -ca_file ca.pem

# --- public CA chain (network) ------------------------------------------------
PROXY=()
if [ -n "${FFMPEG_HTTP_PROXY:-}" ]; then PROXY=(-http_proxy "$FFMPEG_HTTP_PROXY"); fi
echo "[https-trust] E. public HTTPS, system trust: $GOOD"
if ! "$FFMPEG" -hide_banner -loglevel warning -nostdin -tls_verify 0 ${PROXY[@]+"${PROXY[@]}"} \
    -i "$GOOD" -map 0 -c copy -f null - >"$WORK/reach.log" 2>&1; then
  cat "$WORK/reach.log" >&2
  echo "[https-trust] NETWORK UNREACHABLE: $GOOD did not open even with tls_verify=0;" \
    "the public-chain case was NOT verified (fix connectivity or set FFMPEG_HTTP_PROXY)" >&2
  exit 3
fi
if ! "$FFMPEG" -hide_banner -loglevel warning -nostdin -tls_verify 1 ${PROXY[@]+"${PROXY[@]}"} \
    -i "$GOOD" -map 0 -c copy -f null - >"$WORK/trust.log" 2>&1; then
  cat "$WORK/trust.log" >&2
  echo "[https-trust] FAILED: $GOOD opens without verification but not with tls_verify=1 -" \
    "the system trust store is not usable" >&2
  exit 1
fi
echo "[https-trust] PASS"
