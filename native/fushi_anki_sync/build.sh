#!/usr/bin/env bash
# Build fushi-anki-sync (Linux / macOS). Same steps as build.ps1; see README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANKI_TAG=26.09.3
ANKI_COMMIT=29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba
SRC="$HERE/.anki-src"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$ANKI_TAG" https://github.com/ankitects/anki "$SRC"
  git -C "$SRC" submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
fi

head="$(git -C "$SRC" rev-parse HEAD)"
if [ "$head" != "$ANKI_COMMIT" ]; then
  echo ".anki-src is at $head, expected $ANKI_COMMIT (tag $ANKI_TAG). Delete .anki-src and rebuild." >&2
  exit 1
fi

for patch in "$HERE"/patches/*.patch; do
  if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
    continue  # already applied
  fi
  git -C "$SRC" apply "$patch"
done

if [ -z "${PROTOC:-}" ] && ! command -v protoc >/dev/null 2>&1; then
  echo "protoc not found: set PROTOC (Anki pins v31.1) or put it on PATH." >&2
  exit 1
fi

FUSHI_ANKI_SYNC_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/Cargo.toml" | head -n1)"
export FUSHI_ANKI_SYNC_VERSION

cd "$HERE"
if [ "${1:-}" = "--debug" ]; then
  cargo build
else
  cargo build --release
fi
