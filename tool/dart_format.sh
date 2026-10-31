#!/usr/bin/env bash
# Repo-wide `dart format` over every tracked Dart file we own.
#
#   bash tool/dart_format.sh check   # CI gate: exit 1 and list files if any is unformatted
#   bash tool/dart_format.sh fix     # format them in place
#
# Why a gate: until 2026-11-01 nearly half the tracked Dart files were never
# formatted, so every `dart format <touched file>` dragged unrelated reflows
# into diffs and merges. The whole tree was formatted once and this gate keeps
# it that way (main.yml / release.yml run it before analyze; guard
# fushi/test/build/dart_format_gate_guard_test.dart).
#
# Out of scope (never reformatted):
#   third_party/, references/       vendored upstream sources (kept byte-close to upstream)
#   ci/patches/                     patch payloads applied verbatim to the pub cache
#   packages/flutter_inappwebview_{linux,windows}/  forks rebased against upstream
#   *.g.dart / *.freezed.dart / *.mocks.dart        generator output
# Run after pub get: the formatter reads each package's language version from
# .dart_tool/package_config.json.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  check) extra=(--output=none --set-exit-if-changed) ;;
  fix) extra=() ;;
  *)
    echo "usage: bash tool/dart_format.sh check|fix" >&2
    exit 64
    ;;
esac

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
git ls-files -z -- '*.dart' \
  ':(exclude)third_party/**' \
  ':(exclude)references/**' \
  ':(exclude)ci/patches/**' \
  ':(exclude)packages/flutter_inappwebview_linux/**' \
  ':(exclude)packages/flutter_inappwebview_windows/**' \
  ':(exclude,glob)**/*.g.dart' \
  ':(exclude,glob)**/*.freezed.dart' \
  ':(exclude,glob)**/*.mocks.dart' >"$list"

if [ ! -s "$list" ]; then
  echo "dart_format: no Dart files selected (pathspec broken?)" >&2
  exit 1
fi

set +e
# -s 7000: on Windows `dart` is dart.bat, run through cmd.exe and its 8191-char command line.
xargs -0 -s 7000 dart format "${extra[@]}" <"$list"
status=$?
set -e
if [ "$mode" = check ] && [ "$status" -ne 0 ]; then
  echo "::error title=dart format::Unformatted Dart files above. Run: bash tool/dart_format.sh fix" >&2
fi
exit "$status"
