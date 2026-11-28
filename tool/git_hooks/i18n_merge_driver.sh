#!/bin/sh
# Git merge driver entry for fushi/lib/i18n/*.i18n.json (registered by
# tool/setup_worktree.ps1):
#
#   git config merge.fushi-i18n-json.driver \
#     "sh tool/git_hooks/i18n_merge_driver.sh %O %A %B"
#
# Runs fushi/tool/i18n_merge_driver.dart (exit code passed through: 0 merged,
# 1 conflict) with the git repository environment removed.
#
# Why not `dart fushi/tool/i18n_merge_driver.dart` directly: git exports
# GIT_DIR (and GIT_INDEX_FILE / GIT_WORK_TREE ...) to merge drivers. The `dart`
# on PATH is usually the Flutter SDK wrapper (bin/dart(.bat)), which runs
# `git -C "$FLUTTER_ROOT" rev-parse HEAD` to check its cache stamp -- with
# GIT_DIR inherited that reads *this* repository's HEAD, so the SDK thinks it
# changed, rebuilds flutter_tools and rewrites bin/cache/flutter.version.json
# from this repo's tags (2026-11-27: Flutter 3.50.0 reported itself as "2.9.1"
# with the merge commit as framework revision, and tool/bootstrap.ps1 then
# refused the SDK). The driver itself needs no repository: its only git call
# is `git merge-file` on the three temp files.
#
# Dart: the SDK pub get used (flutterRoot in .dart_tool/package_config.json,
# its dart-sdk binary -- no wrapper, no git), else `dart` on PATH.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

here=$(cd "$(dirname "$0")/../.." && pwd)
dart=dart
cfg="$here/.dart_tool/package_config.json"
if [ -f "$cfg" ]; then
  sdk=$(sed -n 's|.*"flutterRoot": *"file://\([^"]*\)".*|\1|p' "$cfg" | head -n 1 |
    sed -e 's|%20| |g' -e 's|^/\([A-Za-z]:\)|\1|')
  for candidate in "$sdk/bin/cache/dart-sdk/bin/dart.exe" "$sdk/bin/cache/dart-sdk/bin/dart"; do
    if [ -n "$sdk" ] && [ -f "$candidate" ]; then
      dart=$candidate
      break
    fi
  done
fi

exec "$dart" "$here/fushi/tool/i18n_merge_driver.dart" "$@"
