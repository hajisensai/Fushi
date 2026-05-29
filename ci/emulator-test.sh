#!/usr/bin/env bash
# Hibiki emulator test workflow
# Usage: bash ci/emulator-test.sh [--skip-build] [--skip-push]
#
# Prerequisites:
#   - Android SDK at D:\android_sdk (emulator + platform-tools)
#   - AVD "hoshi_test" (x86_64, API 30) already created
#   - Flutter at D:\flutter_sdk\flutter_extracted\flutter\bin

set -euo pipefail

# HBK-AUDIT-077: discover tools (PATH first) and allow env overrides instead of
# hardcoding one machine's absolute paths. Defaults match the original setup.
ADB="${ADB:-$(command -v adb 2>/dev/null || echo /d/android_sdk/platform-tools/adb)}"
EMULATOR="${EMULATOR:-$(command -v emulator 2>/dev/null || echo /d/android_sdk/emulator/emulator)}"
FLUTTER="${FLUTTER:-$(command -v flutter 2>/dev/null || echo /d/flutter_sdk/flutter_extracted/flutter/bin/flutter)}"
DEVICE="${DEVICE:-emulator-5554}"
PKG="${PKG:-app.hibiki.reader}"
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

  # HBK-AUDIT-077: source fixtures from env-overridable paths; defaults point at
  # the repo's documented fixtures dir (see hibiki/CLAUDE.md) instead of one
  # developer's personal media. Missing files warn rather than hard-fail.
  FIXTURES_DIR="${FIXTURES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.codex-test/fixtures/kagami}"
  cp "${DICT_ZIP:-/d/辞典/[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip}" "$TMPDIR_LOCAL/meikyo3.zip" 2>/dev/null || echo "WARN: set DICT_ZIP to a dictionary .zip"
  cp "${EPUB_FILE:-$FIXTURES_DIR/かがみの孤城 (辻村深月) (Z-Library).epub}" "$TMPDIR_LOCAL/tensei01.epub" 2>/dev/null || echo "WARN: set EPUB_FILE"
  cp "${SRT_FILE:-$FIXTURES_DIR/かがみの孤城 [audiobook.jp 244083].srt}" "$TMPDIR_LOCAL/tensei01.srt" 2>/dev/null || echo "WARN: set SRT_FILE"
  cp "${M4B_FILE:-$FIXTURES_DIR/かがみの孤城 [audiobook.jp 244083].m4b}" "$TMPDIR_LOCAL/tensei01.m4b" 2>/dev/null || echo "WARN: set M4B_FILE"

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
