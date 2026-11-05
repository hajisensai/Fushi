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

# Apply Flutter SDK (framework Dart source) patches.
#
# Layout: patches/flutter-sdk/<frameworkVersion>/*.patch, unified diffs
# relative to the SDK root (-p1). Framework Dart is compiled into the app
# snapshot, so patching packages/flutter here changes the shipped app without
# rebuilding the engine. Unlike pub-cache patches, a version mismatch is a hard
# failure: silently dropping a framework fix would resurrect the crash it fixes
# (BUG-2839: orphan semantics nodes desync the Windows AX bridge).
if [[ -d "$PATCHES_DIR/flutter-sdk" ]]; then
  if [[ -n "${FLUTTER_ROOT:-}" ]]; then
    sdk_root="$FLUTTER_ROOT"
  else
    flutter_bin="$(command -v flutter || true)"
    if [[ -z "$flutter_bin" ]]; then
      echo "ERROR: flutter-sdk patches present but flutter is not on PATH (set FLUTTER_ROOT)." >&2
      exit 1
    fi
    sdk_root="$(cd "$(dirname "$flutter_bin")/.." && pwd)"
  fi
  if command -v cygpath >/dev/null 2>&1; then
    sdk_root="$(cygpath -u "$sdk_root")"
  fi
  sdk_version=""
  version_json="$sdk_root/bin/cache/flutter.version.json"
  if [[ -f "$version_json" ]]; then
    sdk_version="$(sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "$version_json" | head -n 1)"
  fi
  if [[ -z "$sdk_version" ]] && [[ -f "$sdk_root/version" ]]; then
    sdk_version="$(tr -d '[:space:]' < "$sdk_root/version")"
  fi
  echo "Flutter SDK: $sdk_root ($sdk_version)"
  for ver_dir in "$PATCHES_DIR/flutter-sdk"/*/; do
    ver="$(basename "$ver_dir")"
    if [[ "$ver" != "$sdk_version" ]]; then
      echo "ERROR: flutter-sdk/$ver patches do not match SDK $sdk_version; port or drop them when bumping Flutter." >&2
      exit 1
    fi
  done
  # One SDK is shared by every checkout on the machine (all worktrees here,
  # both slots of a dist_test worker), and branches carry different patch
  # sets: a branch that adds a patch on top of 0001 leaves the SDK in a state
  # where 0001 neither reverse- nor forward-applies, and every other branch's
  # bootstrap / worker prepare then fails. So a git SDK is brought to exactly
  # "its HEAD + this checkout's patch set": modified framework files are
  # restored first, then the set is applied in order. The stamp records the
  # patch set and the resulting `git diff`, so an SDK already in that state
  # (the common case) is left untouched -- rewriting files under a test that
  # is compiling in another checkout is what we must not do needlessly.
  ver_dir="$PATCHES_DIR/flutter-sdk/$sdk_version/"
  sdk_git=(git -C "$sdk_root" -c safe.directory='*' -c core.autocrlf=false)
  if [[ -d "$ver_dir" ]] && "${sdk_git[@]}" rev-parse --git-dir >/dev/null 2>&1; then
    mkdir -p "$sdk_root/bin/cache"
    stamp="$sdk_root/bin/cache/fushi-sdk-patches.stamp"
    lock="$sdk_root/bin/cache/fushi-sdk-patches.lock"
    # Serialize checkouts patching the same SDK. A lock older than 10 minutes
    # belongs to a killed run (patching takes seconds).
    waited=0
    until mkdir "$lock" 2>/dev/null; do
      if [[ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
        rmdir "$lock" 2>/dev/null || true
        continue
      fi
      if [[ "$waited" -ge 600 ]]; then
        echo "ERROR: $lock held for 10 minutes; another checkout is patching this SDK." >&2
        exit 1
      fi
      sleep 1
      waited=$((waited + 1))
    done
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT
    sdk_state() {
      local set_sum diff_sum
      set_sum="$(cat "$ver_dir"*.patch 2>/dev/null | cksum)"
      diff_sum="$("${sdk_git[@]}" diff --no-ext-diff -- packages 2>/dev/null | tr -d '\r' | cksum)"
      echo "$sdk_version set=$set_sum diff=$diff_sum"
    }
    if [[ "$(cat "$stamp" 2>/dev/null || true)" == "$(sdk_state)" ]]; then
      echo "Flutter SDK patches up to date ($(ls "$ver_dir"*.patch 2>/dev/null | wc -l | tr -d ' ') patch(es))."
    else
      rm -f "$stamp"
      modified="$("${sdk_git[@]}" diff --name-only -- packages 2>/dev/null || true)"
      if [[ -n "$modified" ]]; then
        echo "Restoring Flutter SDK framework files to $sdk_root HEAD:"
        echo "$modified" | sed 's/^/  /'
        "${sdk_git[@]}" checkout -- packages
      fi
      for patch_file in "$ver_dir"*.patch; do
        [[ -f "$patch_file" ]] || continue
        name="flutter-sdk/$sdk_version/$(basename "$patch_file")"
        sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$patch_file" | while read -r rel; do
          if [[ -f "$sdk_root/$rel" ]]; then
            tr -d '\r' < "$sdk_root/$rel" > "$sdk_root/$rel.lf"
            mv "$sdk_root/$rel.lf" "$sdk_root/$rel"
          fi
        done
        if ! patch -d "$sdk_root" -p1 -F 0 --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
          echo "ERROR: $name does not apply to $sdk_root HEAD (after the patches before it)." >&2
          exit 1
        fi
        echo "Patching $name ..."
        patch -d "$sdk_root" -p1 -F 0 -s -f < "$patch_file"
      done
      sdk_state > "$stamp"
    fi
    rmdir "$lock" 2>/dev/null || true
    trap - EXIT
    ver_dir=""
  fi
  # Not a git checkout (no HEAD to restore to): patch in place, idempotently.
  for ver_dir in ${ver_dir:+"$ver_dir"}; do
    for patch_file in "$ver_dir"*.patch; do
      [[ -f "$patch_file" ]] || continue
      name="flutter-sdk/$ver/$(basename "$patch_file")"
      # SDK checkouts may be CRLF on Windows; patches are LF. Normalize only the
      # files this patch touches (Dart does not care about line endings).
      # Portable across GNU (Windows/Linux) and BSD (macOS) tools: no sed -i,
      # no GNU-only patch flags. -F 0 demands an exact context match, so GNU
      # patch never writes *.orig mismatch backups into the SDK.
      sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$patch_file" | while read -r rel; do
        if [[ -f "$sdk_root/$rel" ]]; then
          tr -d '\r' < "$sdk_root/$rel" > "$sdk_root/$rel.lf"
          mv "$sdk_root/$rel.lf" "$sdk_root/$rel"
        fi
      done
      if patch -d "$sdk_root" -p1 -F 0 -R --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
        echo "Already applied: $name"
      elif patch -d "$sdk_root" -p1 -F 0 --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
        echo "Patching $name ..."
        patch -d "$sdk_root" -p1 -F 0 -s -f < "$patch_file"
      else
        echo "ERROR: $name does not apply to $sdk_root." >&2
        exit 1
      fi
    done
  done
fi

if [ "$skipped" -ne 0 ]; then
  echo "Patches applied; $skipped patch(es) skipped because their target was not in the pub cache."
else
  echo "All patches applied."
fi
