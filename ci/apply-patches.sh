#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"

# Determine pub cache location
if [ -n "${PUB_CACHE:-}" ]; then
  PUB_CACHE_DIR="$PUB_CACHE"
elif [ -n "${FLUTTER_HOME:-}" ]; then
  PUB_CACHE_DIR="$HOME/.pub-cache"
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
      echo "WARN: $target_dir not found, skipping"
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
      echo "WARN: $target_dir not found, skipping"
      continue
    fi
    echo "Patching git/$pkg_name ..."
    cp -r "$pkg_dir"* "$target_dir/"
  done
fi

echo "All patches applied."
