#!/usr/bin/env bash
set -euo pipefail

# Ensure hibiki/dart_defines.env exists so that
# `flutter build --dart-define-from-file=dart_defines.env` never fails on a
# fresh checkout. The file is gitignored (it may hold per-developer OAuth
# values), but a clean clone has none — so we seed it from the committed
# template. The template ships non-confidential installed-app placeholders, so
# a build using them compiles and runs (only Google Drive backup OAuth stays
# inert until real values are filled in). See HBK-AUDIT-072.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/hibiki/dart_defines.env"
TEMPLATE="$ROOT_DIR/hibiki/dart_defines.env.example"

if [ -f "$ENV_FILE" ]; then
  echo "dart_defines.env already present; leaving it untouched."
  exit 0
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: $TEMPLATE missing; cannot seed dart_defines.env." >&2
  exit 1
fi

cp "$TEMPLATE" "$ENV_FILE"
echo "Seeded dart_defines.env from dart_defines.env.example (placeholder OAuth values)."
