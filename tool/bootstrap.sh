#!/usr/bin/env bash
set -euo pipefail

# One-command setup for a fresh checkout. Collapses the manual pre-build steps
# (seed dart_defines.env -> flutter pub get -> apply pub-cache patches) into a
# single entry point so "git clone + tool/bootstrap.sh + flutter build" works.
#
# Use this when you are NOT going through `melos bootstrap` (which runs the same
# follow-up steps via its post hook). CI invokes `flutter pub get` +
# `ci/apply-patches.sh` directly and does not need this wrapper.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Ensuring dart_defines.env"
bash ci/ensure-dart-defines.sh

echo "==> flutter pub get (hibiki/)"
(cd hibiki && flutter pub get)

echo "==> Applying pub-cache patches"
bash ci/apply-patches.sh

echo ""
echo "Bootstrap complete. Build with, e.g.:"
echo "  cd hibiki && flutter build apk --release --split-per-abi --dart-define-from-file=dart_defines.env"
