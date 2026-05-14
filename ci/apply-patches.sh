#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
missing=0

# Determine pub cache location
if [ -n "${PUB_CACHE:-}" ]; then
  PUB_CACHE_DIR="$PUB_CACHE"
elif [ -n "${LOCALAPPDATA:-}" ]; then
  local_appdata_unix="$LOCALAPPDATA"
  if command -v cygpath >/dev/null 2>&1; then
    local_appdata_unix="$(cygpath -u "$LOCALAPPDATA")"
  fi
  if [ -d "$local_appdata_unix/Pub/Cache" ]; then
    PUB_CACHE_DIR="$local_appdata_unix/Pub/Cache"
  else
    PUB_CACHE_DIR="$HOME/.pub-cache"
  fi
else
  PUB_CACHE_DIR="$HOME/.pub-cache"
fi

echo "Pub cache: $PUB_CACHE_DIR"

# Apply hosted package patches
if [ -d "$PATCHES_DIR/hosted" ]; then
  for pkg_dir in "$PATCHES_DIR/hosted"/*/; do
    pkg_name="$(basename "$pkg_dir")"
    target_dir="$PUB_CACHE_DIR/hosted/pub.dev/$pkg_name"
    if [ ! -d "$target_dir" ]; then
      echo "ERROR: $target_dir not found. Run 'flutter pub get' first or set PUB_CACHE."
      missing=1
      continue
    fi
    echo "Patching hosted/$pkg_name ..."
    cp -r "$pkg_dir"* "$target_dir/"
  done
fi

# Apply git package patches
if [ -d "$PATCHES_DIR/git" ]; then
  for pkg_dir in "$PATCHES_DIR/git"/*/; do
    pkg_name="$(basename "$pkg_dir")"
    target_dir="$PUB_CACHE_DIR/git/$pkg_name"
    if [ ! -d "$target_dir" ]; then
      echo "ERROR: $target_dir not found. Run 'flutter pub get' first or set PUB_CACHE."
      missing=1
      continue
    fi
    echo "Patching git/$pkg_name ..."
    cp -r "$pkg_dir"* "$target_dir/"
  done
fi

if [ "$missing" -ne 0 ]; then
  echo "One or more patch targets were missing; aborting."
  exit 1
fi

echo "All patches applied."
