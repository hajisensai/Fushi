#!/usr/bin/env bash
# AnkiDroid integration test flow for Hibiki.
#
# Verifies the real AddContentApi ContentProvider path end-to-end against a live
# AnkiDroid install on an emulator/device:
#   - AnkiRepository.fetchConfiguration() -> real decks + note types
#   - isDuplicate() against the live collection
#   - mineEntry() add-or-duplicate
# (see hibiki/integration_test/anki_integration_test.dart)
#
# The AnkiDroid provisioning recipe (install + collection + permission grant)
# and its rationale live in ci/lib/provision-ankidroid.sh, shared with the
# all-targets runner ci/integration-test.sh.
#
# Usage:
#   bash ci/anki-integration-test.sh [--skip-build]
#
# Env overrides (defaults match the documented dev setup):
#   ADB, FLUTTER, DEVICE, PKG, ANKI_APK_URL
set -euo pipefail

ADB="${ADB:-$(command -v adb 2>/dev/null || echo /d/android_sdk/platform-tools/adb)}"
FLUTTER="${FLUTTER:-$(command -v flutter 2>/dev/null || echo /d/flutter_sdk/flutter_extracted/flutter/bin/flutter)}"
DEVICE="${DEVICE:-emulator-5554}"
PKG="${PKG:-app.hibiki.reader}"
TARGET="integration_test/anki_integration_test.dart"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SKIP_BUILD=false
for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
  esac
done

ADBD="$ADB -s $DEVICE"
# shellcheck source=ci/lib/provision-ankidroid.sh
source "$REPO_ROOT/ci/lib/provision-ankidroid.sh"

cd "$REPO_ROOT/hibiki"

# --- 1. Device online ---
if ! $ADB devices 2>/dev/null | grep -q "$DEVICE[[:space:]].*device"; then
  echo ">>> FAIL: device $DEVICE not connected. Start the emulator first." >&2
  exit 1
fi

# --- 2-3. Install AnkiDroid + ensure a collection exists ---
if ! provision_ankidroid; then
  echo ">>> FAIL: AnkiDroid could not be provisioned. Open AnkiDroid once" >&2
  echo "    manually (tap 'Get started') and re-run." >&2
  exit 1
fi

# --- 4. Build the debug APK ---
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building debug APK..."
  $FLUTTER build apk --debug --target-platform android-x64
fi

# --- 5. Pre-install with all runtime perms granted, then verify the grant ---
echo ">>> Installing app with runtime permissions granted..."
MSYS_NO_PATHCONV=1 $ADBD install -r -g build/app/outputs/flutter-apk/app-debug.apk
if ! grant_hibiki_ankidroid_permission; then
  echo ">>> FAIL: could not grant the AnkiDroid API permission to $PKG." >&2
  exit 1
fi

# --- 6. Run the AnkiDroid integration test ---
echo ">>> Running $TARGET..."
$FLUTTER drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d "$DEVICE"

echo ">>> AnkiDroid integration test complete."
