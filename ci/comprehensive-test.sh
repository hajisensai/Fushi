#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/hibiki"

DART="${DART:-dart}"
if [[ "${SKIP_FIXTURES:-}" != "1" ]]; then
  "$DART" run tool/generate_test_fixtures.dart --output=../.codex-test/fixtures
fi
"$DART" run tool/comprehensive_test_runner.dart "$@"
