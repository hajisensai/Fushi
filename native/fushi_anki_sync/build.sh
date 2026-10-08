#!/usr/bin/env bash
# Build fushi-anki-sync (Linux / macOS). Same steps as build.ps1; see README.md.
#
#   build.sh [--debug] [--install-dir DIR] [--prebuilt-binary FILE]
#
#   On macOS the helper is built for the host architecture only: the macOS app ships
#   Apple Silicon (arm64) only, Intel Macs are no longer supported, so CI builds it on
#   an arm64 runner and release-desktop.yml checks the slice matches the app binary.
#   --install-dir  copy the binary and its AGPL source notice (fushi-anki-sync.SOURCE.txt)
#                  into DIR, then smoke-test the installed copy. CI uses this to bundle
#                  the helper next to the app / server executable.
#   --prebuilt-binary  skip clone / patch / cargo and install + smoke-test FILE instead
#                  (requires --install-dir). CI passes it when .github/actions/native-artifact-store
#                  restored a binary built from this exact directory tree, so the source
#                  notice and the smoke test below still run against what actually ships.
#                  Same contract as build.ps1 -PrebuiltBinary.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANKI_TAG=26.09.3
ANKI_COMMIT=29bb700b951e3f0c0cb69b77c0180fc1fe33e6ba
SRC="$HERE/.anki-src"

PROFILE=release
INSTALL_DIR=""
PREBUILT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) PROFILE=debug ;;
    --install-dir)
      INSTALL_DIR="${2:?--install-dir needs a directory}"
      shift
      ;;
    --prebuilt-binary)
      PREBUILT="${2:?--prebuilt-binary needs a file}"
      shift
      ;;
    *)
      echo "unknown argument: $1 (usage: build.sh [--debug] [--install-dir DIR] [--prebuilt-binary FILE])" >&2
      exit 2
      ;;
  esac
  shift
done

# The build below runs from $HERE, so a relative --install-dir must be resolved against
# the caller's working directory first (CI passes paths relative to the repo root).
if [ -n "$INSTALL_DIR" ]; then
  case "$INSTALL_DIR" in
    /*) ;;
    *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
  esac
fi
if [ -n "$PREBUILT" ]; then
  if [ -z "$INSTALL_DIR" ]; then
    echo "--prebuilt-binary requires --install-dir (there is nothing to build)." >&2
    exit 2
  fi
  case "$PREBUILT" in
    /*) ;;
    *) PREBUILT="$PWD/$PREBUILT" ;;
  esac
  if [ ! -f "$PREBUILT" ]; then
    echo "prebuilt fushi-anki-sync not found at $PREBUILT" >&2
    exit 1
  fi
fi

FUSHI_ANKI_SYNC_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/Cargo.toml" | head -n1)"
export FUSHI_ANKI_SYNC_VERSION

if [ -n "$PREBUILT" ]; then
  BIN="$PREBUILT"
else
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

  cd "$HERE"
  # Unquoted on purpose: empty in debug builds (bash 3.2 on macOS rejects "${arr[@]}"
  # of an empty array under set -u).
  release_flag="--release"
  [ "$PROFILE" = debug ] && release_flag=""
  cargo build $release_flag
  BIN="target/$PROFILE/fushi-anki-sync"
fi

if [ -z "$INSTALL_DIR" ]; then
  exit 0
fi

mkdir -p "$INSTALL_DIR"
cp "$BIN" "$INSTALL_DIR/fushi-anki-sync"
chmod +x "$INSTALL_DIR/fushi-anki-sync"

# AGPL: every shipped binary carries where its exact source lives. The commit is the
# checkout being built (in a reusable workflow GITHUB_SHA is the caller's repo, not ours).
commit="${FUSHI_SOURCE_COMMIT:-$(git -C "$HERE" rev-parse HEAD)}"
repo="${FUSHI_SOURCE_REPO:-hajisensai/Fushi}"
sed -e "s|@VERSION@|$FUSHI_ANKI_SYNC_VERSION|g" \
    -e "s|@ANKI_TAG@|$ANKI_TAG|g" \
    -e "s|@ANKI_COMMIT@|$ANKI_COMMIT|g" \
    -e "s|@REPO@|$repo|g" \
    -e "s|@COMMIT@|$commit|g" \
    "$HERE/SOURCE.txt.in" > "$INSTALL_DIR/fushi-anki-sync.SOURCE.txt"

# Smoke the installed copy: it must start, answer the protocol and report the honest
# "fushi,<version> (anki <tag>)" identity (proves the version patch was applied).
reply="$(printf '%s\n' '{"id":1,"cmd":"version"}' | "$INSTALL_DIR/fushi-anki-sync")"
echo "fushi-anki-sync version reply: $reply"
case "$reply" in
  *"\"client\":\"fushi,$FUSHI_ANKI_SYNC_VERSION (anki $ANKI_TAG),"*) ;;
  *)
    echo "fushi-anki-sync smoke failed: expected client fushi,$FUSHI_ANKI_SYNC_VERSION (anki $ANKI_TAG),<os>" >&2
    exit 1
    ;;
esac
ls -l "$INSTALL_DIR/fushi-anki-sync" "$INSTALL_DIR/fushi-anki-sync.SOURCE.txt"
