#!/usr/bin/env bash
# Fully-automated, EMULATOR-ONLY integration test runner for Hibiki.
#
# One command: boots/selects an emulator, builds the debug APK once, provisions
# every prerequisite (AnkiDroid + a collection + permission grant, dictionary
# fixture on /sdcard), then runs EVERY integration_test target and aggregates
# the results. No real device, no manual `flutter drive`, no manual adb
# push/tap. A real (physical) device is deliberately ignored — only serials
# matching emulator-<port> are used.
#
# Usage:
#   bash ci/integration-test.sh                      # boot/select emulator, run all
#   bash ci/integration-test.sh --skip-build         # reuse the existing app-debug.apk
#   bash ci/integration-test.sh --only=app_smoke,reader_pagination
#   bash ci/integration-test.sh --avd=hoshi_test_api35
#
# Env overrides: ADB, EMULATOR, FLUTTER, AVD, PKG, DICT_ZIP, ANKI_APK_URL
#
# NOTE: this runner does NOT use `set -e` — a failing target must not abort the
# remaining targets; failures are collected and reported in the final summary.
set -uo pipefail

ADB="${ADB:-$(command -v adb 2>/dev/null || echo /d/android_sdk/platform-tools/adb)}"
EMULATOR="${EMULATOR:-$(command -v emulator 2>/dev/null || echo /d/android_sdk/emulator/emulator)}"
FLUTTER="${FLUTTER:-$(command -v flutter 2>/dev/null || echo /d/flutter_sdk/flutter_extracted/flutter/bin/flutter)}"
AVD="${AVD:-hoshi_test_api35}"
PKG="${PKG:-app.hibiki.reader}"
DICT_ZIP="${DICT_ZIP:-/d/辞典/[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip}"
APK_REL="build/app/outputs/flutter-apk/app-debug.apk"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SKIP_BUILD=false
ONLY=""
for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --avd=*) AVD="${arg#*=}" ;;
    --only=*) ONLY="${arg#*=}" ;;
    *) echo ">>> Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ── Emulator-only selection. A physical device serial does not match
# emulator-<port>, so this guard guarantees we never touch a real device. ──
emulator_serial() {
  $ADB devices 2>/dev/null | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}'
}

DEVICE="$(emulator_serial)"
if [ -z "$DEVICE" ]; then
  echo ">>> No emulator online — booting AVD '$AVD'..."
  "$EMULATOR" -avd "$AVD" -no-snapshot-save -gpu host >/dev/null 2>&1 &
  for _ in $(seq 1 120); do
    DEVICE="$(emulator_serial)"
    [ -n "$DEVICE" ] && break
    sleep 2
  done
  if [ -z "$DEVICE" ]; then
    echo ">>> FAIL: emulator did not appear after 240s." >&2
    exit 1
  fi
fi
ADBD="$ADB -s $DEVICE"
echo ">>> Using emulator: $DEVICE"

until [ "$(MSYS_NO_PATHCONV=1 $ADBD shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
  echo ">>> waiting for boot..."
  sleep 2
done
echo ">>> Emulator booted."

# shellcheck source=ci/lib/provision-ankidroid.sh
source "$REPO_ROOT/ci/lib/provision-ankidroid.sh"

cd "$REPO_ROOT/hibiki"

# ── Build once ──
if [ "$SKIP_BUILD" = false ]; then
  echo ">>> Building debug APK (once)..."
  if ! "$FLUTTER" build apk --debug; then
    echo ">>> FAIL: build failed." >&2
    exit 1
  fi
fi
if [ ! -f "$APK_REL" ]; then
  echo ">>> FAIL: $APK_REL not found (run without --skip-build first)." >&2
  exit 1
fi

# ── Pre-install with all runtime perms granted (preserved across flutter
#    drive's -r reinstall, so the AnkiDroid grant survives the run). ──
echo ">>> Pre-installing Hibiki with runtime permissions granted..."
MSYS_NO_PATHCONV=1 $ADBD install -r -g "$APK_REL"

# ── Provision external prerequisites (best effort; failures only affect the
#    targets that need them, reported in the summary). ──
ANKI_OK=false
if provision_ankidroid && grant_hibiki_ankidroid_permission; then
  ANKI_OK=true
else
  echo ">>> WARN: AnkiDroid not fully provisioned — anki_integration may fail." >&2
fi

DICT_OK=false
if [ -f "$DICT_ZIP" ]; then
  echo ">>> Pushing dictionary fixture to /sdcard/Download/test_dict.zip..."
  if MSYS_NO_PATHCONV=1 $ADBD push "$DICT_ZIP" /sdcard/Download/test_dict.zip >/dev/null; then
    DICT_OK=true
  fi
else
  echo ">>> WARN: DICT_ZIP not found ($DICT_ZIP) — popup_dictionary may fail." >&2
fi

# ── Target list (classified by prerequisite for the summary) ──
ALL_TARGETS=(
  app_smoke settings_validation navigation_stability home_keyboard
  gamepad_navigation feature_flows
  reader_pagination reader_caret reader_popup_caret
  popup_dictionary anki_integration
  regression user_path reader_dictionary reader_keyboard
)

TARGETS=()
if [ -n "$ONLY" ]; then
  IFS=',' read -ra TARGETS <<< "$ONLY"
else
  TARGETS=("${ALL_TARGETS[@]}")
fi

PASS=(); FAIL=(); SKIP=()
LOGDIR="$REPO_ROOT/.codex-test/itest-logs"
mkdir -p "$LOGDIR"

run_target() {
  local t="$1"
  local file="integration_test/${t}_test.dart"
  if [ ! -f "$file" ]; then
    echo ">>> SKIP $t (no such target)"
    SKIP+=("$t")
    return
  fi
  echo ">>> RUN  $t"
  local log="$LOGDIR/${t}.log"
  if "$FLUTTER" drive \
        --driver=test_driver/integration_test.dart \
        --target="$file" -d "$DEVICE" >"$log" 2>&1 \
     && grep -q "All tests passed" "$log"; then
    echo ">>> PASS $t"
    PASS+=("$t")
  else
    echo ">>> FAIL $t  (see $log)"
    FAIL+=("$t")
    grep -iE "fail\(|Expected:|Exception|Error:|No books|Dictionary fixture|AnkiFetch" "$log" | head -3
  fi
}

for t in "${TARGETS[@]}"; do
  run_target "$t"
done

echo ""
echo "==================== INTEGRATION SUMMARY ===================="
echo "Emulator     : $DEVICE"
echo "AnkiDroid    : $([ "$ANKI_OK" = true ] && echo provisioned || echo NOT-provisioned)"
echo "Dictionary   : $([ "$DICT_OK" = true ] && echo pushed || echo NOT-pushed)"
echo "PASS (${#PASS[@]}): ${PASS[*]:-none}"
echo "SKIP (${#SKIP[@]}): ${SKIP[*]:-none}"
echo "FAIL (${#FAIL[@]}): ${FAIL[*]:-none}"
echo "Logs         : $LOGDIR"
echo "============================================================"

[ ${#FAIL[@]} -eq 0 ]
