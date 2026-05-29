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
# WHY THIS NEEDS ITS OWN FLOW
# ---------------------------
# The AnkiDroid API is gated by the *dangerous* permission
#   com.ichi2.anki.permission.READ_WRITE_DATABASE
# which Android grants only after the user taps "Allow" on AnkiDroid's runtime
# dialog. Hibiki requests it correctly at runtime (AnkiChannelHandler.java
# ankiDroid.requestPermission(...)), but an automated `flutter drive` run
# installs the app fresh and cannot tap that system dialog, so every fresh-install
# run returns AnkiFetchError. We reproduce the *granted* state deterministically:
# pre-install the debug APK with `adb install -g` (grant all runtime perms, i.e.
# simulate the user tapping Allow); `flutter drive`'s `-r` reinstall then
# PRESERVES the grant for the instrumented run. This is a harness setup step, not
# a workaround in product code.
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
ANKI_PKG="com.ichi2.anki"
# F-Droid mirror APK that is known to work (github/cloudflare are bot-gated).
ANKI_APK_URL="${ANKI_APK_URL:-https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo/com.ichi2.anki_22400300.apk}"
ANKI_PERM="com.ichi2.anki.permission.READ_WRITE_DATABASE"
TARGET="integration_test/anki_integration_test.dart"
COLLECTION="/storage/emulated/0/AnkiDroid/collection.anki2"
TAP="$(cd "$(dirname "$0")/.." && pwd)/.codex-test/tools/tap-element.sh"

SKIP_BUILD=false
for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
  esac
done

cd "$(dirname "$0")/../hibiki"
ADBD="$ADB -s $DEVICE"

# --- 1. Device online ---
if ! $ADB devices 2>/dev/null | grep -q "$DEVICE[[:space:]].*device"; then
  echo ">>> FAIL: device $DEVICE not connected. Start the emulator first." >&2
  exit 1
fi

# --- 2. Ensure AnkiDroid installed ---
if ! MSYS_NO_PATHCONV=1 $ADBD shell pm path "$ANKI_PKG" >/dev/null 2>&1; then
  echo ">>> AnkiDroid not installed; downloading from mirror..."
  TMP_ANKI="$(pwd)/.anki_apk_download.apk"
  curl -L --ssl-no-revoke -o "$TMP_ANKI" "$ANKI_APK_URL"
  MSYS_NO_PATHCONV=1 $ADBD install "$TMP_ANKI"
  rm -f "$TMP_ANKI"
else
  echo ">>> AnkiDroid already installed."
fi

# --- 3. Ensure storage permission + a collection exists ---
MSYS_NO_PATHCONV=1 $ADBD shell appops set "$ANKI_PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
MSYS_NO_PATHCONV=1 $ADBD shell pm grant "$ANKI_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $COLLECTION" >/dev/null 2>&1; then
  echo ">>> No AnkiDroid collection; running first-launch onboarding..."
  MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 6
  # Dismiss onboarding via uiautomator (never blind-tap coordinates).
  bash "$TAP" "Get started" "$DEVICE" 2>/dev/null || \
    bash "$TAP" "started" "$DEVICE" 2>/dev/null || true
  sleep 4
  MSYS_NO_PATHCONV=1 $ADBD shell am force-stop "$ANKI_PKG" || true
  MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 6
  if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $COLLECTION" >/dev/null 2>&1; then
    echo ">>> FAIL: AnkiDroid collection still not created. Open AnkiDroid once" >&2
    echo "    manually (tap 'Get started') and re-run." >&2
    exit 1
  fi
fi
echo ">>> AnkiDroid collection present."

# --- 4. Build the debug APK ---
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building debug APK..."
  $FLUTTER build apk --debug --target-platform android-x64
fi

# --- 5. Pre-install with all runtime perms granted (simulates user tapping
#        Allow on AnkiDroid's READ_WRITE_DATABASE dialog). flutter drive's `-r`
#        reinstall then preserves this grant for the instrumented run. ---
echo ">>> Installing app with runtime permissions granted..."
MSYS_NO_PATHCONV=1 $ADBD install -r -g build/app/outputs/flutter-apk/app-debug.apk
MSYS_NO_PATHCONV=1 $ADBD shell pm grant "$PKG" "$ANKI_PERM" >/dev/null 2>&1 || true
GRANTED=$(MSYS_NO_PATHCONV=1 $ADBD shell dumpsys package "$PKG" 2>/dev/null | grep "$ANKI_PERM: granted=true" || true)
if [ -z "$GRANTED" ]; then
  echo ">>> FAIL: could not grant $ANKI_PERM to $PKG." >&2
  exit 1
fi
echo ">>> $ANKI_PERM granted=true."

# --- 6. Run the AnkiDroid integration test ---
echo ">>> Running $TARGET..."
$FLUTTER drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d "$DEVICE"

echo ">>> AnkiDroid integration test complete."
