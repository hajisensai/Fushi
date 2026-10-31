#!/usr/bin/env bash
# One-time setup of a dist_test worker on macOS / Linux, run BY THE MACHINE'S
# OWNER in the dedicated low-privilege account (e.g. `fushitest`), never by
# the requester (docs/specs/2026-10-24-distributed-unit-tests.md §6-§7).
#
#   bash worker_setup.sh "ssh-ed25519 AAAA... fushi-dist" [--no-seed]
#
# What it does, all inside this account's home:
#   - copies worker_shim.sh to ~/.fushi-worker/shim (read it first: it is the
#     whole interface the key gets);
#   - writes ~/.fushi-worker/limits and ~/.fushi-worker/path if missing;
#   - bare-clones the public repo to ~/.fushi-worker/seed (unless --no-seed);
#   - appends the key to ~/.ssh/authorized_keys pinned to the shim:
#       restrict,command="bash ~/.fushi-worker/shim" <key>
#     `restrict` turns off port / agent / X11 forwarding and the pty;
#     `command=` means this key can run nothing but the shim.
#
# Afterwards: `bash ~/.fushi-worker/shim pause|resume|status`.
# Prerequisites it checks but does not install: git, Flutter (the version in
# fushi/.fvmrc), Rust (cargo).
set -euo pipefail

key=${1:-}
case "$key" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;;
  *) echo "usage: bash $0 \"ssh-ed25519 AAAA... comment\"" >&2; exit 2 ;;
esac
case "$key" in
  *'"'*|*,*command=*) echo "error: pass the bare public key line" >&2; exit 2 ;;
esac

SEED_URL=https://github.com/hajisensai/fushi
here=$(cd "$(dirname "$0")" && pwd)
W="$HOME/.fushi-worker"
mkdir -p "$W" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
install -m 0644 "$here/worker_shim.sh" "$W/shim"
echo "installed $W/shim"

if [ ! -f "$W/limits" ]; then
  cat > "$W/limits" <<'LIMITS'
# dist_test worker limits (KEY=number). Edit freely; the requester cannot.
MAX_SLOTS=1
# MAX_CONCURRENCY=4
MIN_FREE_MEM_MB=4096
MIN_FREE_DISK_GB=20
# Compile checks (Android / desktop builds whose output never leaves this
# machine); 0 turns them off.
# ALLOW_BUILD=0
LIMITS
  echo "wrote $W/limits"
fi

if [ ! -f "$W/path" ]; then
  : > "$W/path"
  for tool in flutter cargo; do
    if command -v "$tool" > /dev/null 2>&1; then
      dirname "$(command -v "$tool")" >> "$W/path"
    fi
  done
  for d in "$HOME/flutter/bin" "$HOME/.cargo/bin" /opt/homebrew/bin; do
    [ -d "$d" ] && ! grep -qx "$d" "$W/path" && echo "$d" >> "$W/path"
  done
  echo "wrote $W/path:"
  sed 's/^/  /' "$W/path"
fi

# Seed: a bare clone of the public repo whose objects every checkout borrows,
# so the requester's pushes only carry their new commits (the full history is
# gigabytes). `git -C ~/.fushi-worker/seed fetch` now and then keeps it close.
if [ "${2:-}" != "--no-seed" ] && [ ! -d "$W/seed" ]; then
  echo "cloning the seed repository (bare, a few GB; --no-seed skips)"
  git clone --bare --quiet "$SEED_URL" "$W/seed"
fi

line="restrict,command=\"bash ~/.fushi-worker/shim\" $key"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if grep -qF "$key" "$HOME/.ssh/authorized_keys"; then
  echo "key already in authorized_keys (left as it is; check it carries the"
  echo "restrict,command= prefix above)"
else
  echo "$line" >> "$HOME/.ssh/authorized_keys"
  echo "added the key, pinned to the shim"
fi

echo
echo "== self check (what the requester's 'hello' will see)"
SSH_ORIGINAL_COMMAND=hello bash "$W/shim" || true
