#!/usr/bin/env bash
# Hibiki emulator test workflow
# Usage: bash ci/emulator-test.sh [--skip-build] [--skip-push]
#
# Prerequisites:
#   - Android SDK at D:\android_sdk (emulator + platform-tools)
#   - AVD "hoshi_test" (x86_64, API 30) already created
#   - Flutter at D:\flutter_sdk\flutter_extracted\flutter\bin

set -euo pipefail

ADB="/d/android_sdk/platform-tools/adb"
EMULATOR="/d/android_sdk/emulator/emulator"
FLUTTER="/d/flutter_sdk/flutter_extracted/flutter/bin/flutter"
DEVICE="emulator-5554"
PKG="app.hibiki.reader"
APK="build/app/outputs/flutter-apk/app-release.apk"
SCREENSHOT_DIR="../test_screenshots"

SKIP_BUILD=false
SKIP_PUSH=false
for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --skip-push)  SKIP_PUSH=true ;;
  esac
done

cd "$(dirname "$0")/../hibiki"

# --- 1. Start emulator if not running ---
if ! $ADB devices 2>/dev/null | grep -q "$DEVICE.*device"; then
  echo ">>> Starting emulator hoshi_test..."
  $EMULATOR -avd hoshi_test -no-snapshot-load &
  $ADB wait-for-device
  # Wait for boot
  until [ "$($ADB -s $DEVICE shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
    sleep 2
  done
  echo ">>> Emulator booted."
else
  echo ">>> Emulator already running."
fi

# --- 2. Build universal APK (x86_64 + arm64) ---
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building universal release APK..."
  $FLUTTER build apk --release
  echo ">>> APK built: $APK"
fi

# --- 3. Install ---
echo ">>> Installing APK..."
MSYS_NO_PATHCONV=1 $ADB -s $DEVICE uninstall $PKG 2>/dev/null || true
MSYS_NO_PATHCONV=1 $ADB -s $DEVICE install "$APK"
echo ">>> Installed."

# --- 4. Push test resources ---
if [ "$SKIP_PUSH" = false ]; then
  echo ">>> Pushing test resources..."
  TMPDIR_LOCAL="/d/tmp_hibiki_test"
  mkdir -p "$TMPDIR_LOCAL"

  # Dictionary
  cp "/d/辞典/[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip" "$TMPDIR_LOCAL/meikyo3.zip"
  # EPUB
  cp "/c/Users/wrds/Downloads/転生王女と天才令嬢の魔法革命 01 .epub" "$TMPDIR_LOCAL/tensei01.epub"
  # SRT
  cp "/c/Users/wrds/Downloads/[01] 転生王女と天才令嬢の魔法革命 【オーディオブック特典付き】 [B0CC5WC1PK](2).srt" "$TMPDIR_LOCAL/tensei01.srt"
  # M4B audiobook
  cp "/d/downloads/Bangumi/Audiobook Collection/[鴉 ぴえろ] 転生王女と天才令嬢の魔法革命/[01] 転生王女と天才令嬢の魔法革命 【オーディオブック特典付き】 [B0CC5WC1PK].m4b" "$TMPDIR_LOCAL/tensei01.m4b"

  MSYS_NO_PATHCONV=1 $ADB -s $DEVICE push "$TMPDIR_LOCAL/meikyo3.zip"    /sdcard/Download/meikyo3.zip
  MSYS_NO_PATHCONV=1 $ADB -s $DEVICE push "$TMPDIR_LOCAL/tensei01.epub"  /sdcard/Download/tensei01.epub
  MSYS_NO_PATHCONV=1 $ADB -s $DEVICE push "$TMPDIR_LOCAL/tensei01.srt"   /sdcard/Download/tensei01.srt
  MSYS_NO_PATHCONV=1 $ADB -s $DEVICE push "$TMPDIR_LOCAL/tensei01.m4b"   /sdcard/Download/tensei01.m4b

  rm -rf "$TMPDIR_LOCAL"
  echo ">>> Resources pushed."
fi

# --- 5. Launch & screenshot ---
echo ">>> Launching $PKG..."
MSYS_NO_PATHCONV=1 $ADB -s $DEVICE shell am start -n $PKG/.MainActivity
sleep 5

mkdir -p "$SCREENSHOT_DIR"
MSYS_NO_PATHCONV=1 $ADB -s $DEVICE exec-out screencap -p > "$SCREENSHOT_DIR/emulator_test_$(date +%Y%m%d_%H%M%S).png"
echo ">>> Screenshot saved to $SCREENSHOT_DIR/"

# --- 6. Smoke check: app still alive ---
if MSYS_NO_PATHCONV=1 $ADB -s $DEVICE shell pidof $PKG > /dev/null 2>&1; then
  echo ">>> PASS: App is running."
else
  echo ">>> FAIL: App crashed on launch!"
  MSYS_NO_PATHCONV=1 $ADB -s $DEVICE logcat -d -t 30 | grep -iE "fatal|crash|exception" | tail -10
  exit 1
fi

echo ">>> Test workflow complete."
echo ""
echo "Test resources on emulator (/sdcard/Download/):"
echo "  - meikyo3.zip       (明鏡国語辞典 第三版)"
echo "  - tensei01.epub     (転生王女と天才令嬢の魔法革命 01)"
echo "  - tensei01.srt      (字幕)"
echo "  - tensei01.m4b      (有声书音频)"
