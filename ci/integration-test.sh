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
# Dictionary fixture for popup_dictionary / reader_dictionary. Those tests look
# up basic vocabulary (猫 / 食べる), so the fixture must be a GENERAL J-J/J-C
# dictionary — a grammar/bunkei dict would return zero results and fail them.
# Resolution (below): explicit DICT_ZIP, else a general dict matched by name
# under DICT_DIR, else any zip as a last resort.
DICT_DIR="${DICT_DIR:-/d/辞典}"
DICT_ZIP="${DICT_ZIP:-}"

# Convert an MSYS path (/d/foo) to a Windows path (D:/foo) so the native
# adb.exe can stat the local push source. adb push needs MSYS_NO_PATHCONV=1 for
# the /sdcard destination, which also disables conversion of the source — so a
# /d/... source reaches adb verbatim and fails to stat. Pre-converting the
# source to D:/... makes both ends valid under MSYS_NO_PATHCONV=1.
win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    echo "$1" | sed -E 's#^/([a-zA-Z])/#\U\1:/#'
  fi
}
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

# All-Files-Access (MANAGE_EXTERNAL_STORAGE) is an appop, NOT a runtime
# permission, so `install -g` does not grant it. Without it the app process gets
# "Permission denied" reading the dictionary fixture the runner pushed to
# /sdcard/Download (scoped storage blocks the app uid even though adb's shell
# uid could write there). Grant the appop so popup_dictionary / reader_dictionary
# can read the fixture; the grant survives flutter drive's -r reinstall.
MSYS_NO_PATHCONV=1 $ADBD shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true

# ── Provision external prerequisites (best effort; failures only affect the
#    targets that need them, reported in the summary). ──
ANKI_OK=false
if provision_ankidroid && grant_hibiki_ankidroid_permission; then
  ANKI_OK=true
else
  echo ">>> WARN: AnkiDroid not fully provisioned — anki_integration may fail." >&2
fi

DICT_OK=false
# Resolve the dictionary fixture: explicit DICT_ZIP, else a GENERAL dictionary
# matched by name (明鏡/明镜/国語/国语 — these have the basic vocab the lookup
# tests search for), else any zip as a last resort. `find` tolerates the
# [..]/CJK characters that break a literal path match.
if [ -z "$DICT_ZIP" ] || [ ! -f "$DICT_ZIP" ]; then
  DICT_ZIP="$(find "$DICT_DIR" -maxdepth 1 \
      \( -name '*明鏡*.zip' -o -name '*明镜*.zip' -o -name '*国語*.zip' \
         -o -name '*国语*.zip' \) 2>/dev/null | head -1)"
  [ -z "$DICT_ZIP" ] && \
    DICT_ZIP="$(find "$DICT_DIR" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1)"
fi
if [ -n "$DICT_ZIP" ] && [ -f "$DICT_ZIP" ]; then
  # Push into the app's OWN external-files dir, which the app process reads with
  # NO permission (getExternalStorageDirectory()). /sdcard/Download is blocked
  # for the app uid under scoped storage even though adb's shell uid can write
  # there, which is why the dict tests previously failed with "Permission
  # denied" (the app — not the shell — opens the file). The app must already be
  # installed (it is: pre-install ran above) so the dir exists.
  DICT_DEST="/sdcard/Android/data/$PKG/files/test_dict.zip"
  echo ">>> Pushing dictionary fixture ($(basename "$DICT_ZIP")) to $DICT_DEST..."
  MSYS_NO_PATHCONV=1 $ADBD shell mkdir -p "/sdcard/Android/data/$PKG/files" >/dev/null 2>&1 || true
  # Push from a Windows-form source path (see win_path) under MSYS_NO_PATHCONV.
  if MSYS_NO_PATHCONV=1 $ADBD push "$(win_path "$DICT_ZIP")" "$DICT_DEST" >/dev/null; then
    DICT_OK=true
  fi
else
  echo ">>> WARN: no dictionary zip found under $DICT_DIR — popup_dictionary may fail." >&2
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
if [ ${#TARGETS[@]} -eq 0 ]; then
  echo ">>> FAIL: no targets to run (empty --only?)." >&2
  exit 2
fi

PASS=(); FAIL=(); SKIP=(); NOTES=()
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
  # A target passes only if flutter drive exits 0, the log shows "All tests
  # passed", and it does NOT also report "Some tests failed" (belt-and-
  # suspenders against a 0-test run that exits 0 with no clear verdict).
  if "$FLUTTER" drive \
        --driver=test_driver/integration_test.dart \
        --target="$file" -d "$DEVICE" >"$log" 2>&1 \
     && grep -q "All tests passed" "$log" \
     && ! grep -q "Some tests failed" "$log"; then
    echo ">>> PASS $t"
    PASS+=("$t")
    # Surface intentionally-skipped sub-assertions (e.g. regression's
    # HBK-REG-001 play-bar geometry, which only runs with a real audiobook) so
    # a green PASS is not mistaken for full coverage.
    local skipped
    skipped=$(grep -ioE "SKIP [A-Z0-9_-]+" "$log" | sort -u | tr '\n' ' ')
    [ -n "$skipped" ] && NOTES+=("$t: ${skipped% }")
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
if [ ${#NOTES[@]} -gt 0 ]; then
  echo "NOTES (partial coverage — passed but with skipped sub-assertions):"
  printf '  - %s\n' "${NOTES[@]}"
fi
echo "Logs         : $LOGDIR"
echo "============================================================"

# Green only if nothing failed AND at least one target actually passed — so a
# run where every requested target was skipped (e.g. a mistyped --only) does
# not report a misleading success (review W1).
[ ${#FAIL[@]} -eq 0 ] && [ ${#PASS[@]} -gt 0 ]
