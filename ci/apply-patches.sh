#!/usr/bin/env bash
set -euo pipefail

# Patch dirs are named by exact package version (e.g. win32-4.1.4). When the
# resolved lock moves to a different version, the pub-cache target dir is named
# after the NEW version, so the old patch's target is simply absent. A missing
# target therefore means "this patch no longer applies" — skip it with a
# warning instead of hard-failing the whole build (HBK-AUDIT-005).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
skipped=0

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
      echo "WARNING: hosted/$pkg_name not in pub cache (version drifted or dependency removed); skipping."
      skipped=$((skipped + 1))
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
      echo "WARNING: git/$pkg_name not in pub cache (fork removed or revision changed); skipping."
      skipped=$((skipped + 1))
      continue
    fi
    echo "Patching git/$pkg_name ..."
    cp -r "$pkg_dir"* "$target_dir/"
  done
fi

if [ "$skipped" -ne 0 ]; then
  echo "Patches applied; $skipped patch(es) skipped because their target was not in the pub cache."
else
  echo "All patches applied."
fi
