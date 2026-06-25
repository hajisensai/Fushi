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

# NOTE: win_path() (MSYS /d/foo -> Windows D:/foo for native adb.exe) is provided
# by ci/lib/provision-ankidroid.sh, which is sourced below before any caller uses
# it (the dictionary push at the bottom of this script). Defining it in the
# shared lib keeps it usable by the APK install there too (single definition).
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
  # GPU mode is overridable via GPU_MODE; default host. NOTE: the emulator logs
  # "aw_browser_terminator: Renderer process crash detected" during WebView
  # pre-warm under BOTH host and software rendering — it is harmless noise, not
  # a test failure (reader_pagination passes with those crashes present). Do
  # NOT treat that log line as a root cause.
  "$EMULATOR" -avd "$AVD" -no-snapshot-save -gpu "${GPU_MODE:-host}" >/dev/null 2>&1 &
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
MSYS_NO_PATHCONV=1 $ADBD install -r -g "$(win_path "$APK_REL")"

# Re-enable the default launcher activity-alias. Hibiki's runtime icon switcher
# (IconSwitchHelper) disables .MainActivityDefault when the user picks a
# different launcher icon; a fresh `install -r` can land with that alias still
# disabled, leaving the app with no enabled LAUNCHER component — `flutter drive`
# then resolves no launchable activity. Idempotent (no-op if already enabled);
# non-fatal so a manifest rename never aborts the run.
MSYS_NO_PATHCONV=1 $ADBD shell pm enable "$PKG/.MainActivityDefault" >/dev/null 2>&1 || true

# All-Files-Access (MANAGE_EXTERNAL_STORAGE) is an appop, NOT a runtime
# permission, so `install -g` does not grant it. Without it the app process gets
# "Permission denied" (errno 13) reading the dictionary fixture pushed to
# /sdcard/Download (scoped storage blocks the app uid even though adb's shell
# uid can write there). It must be set with `--uid` (the per-package form fails
# on API 35), and the grant DOES survive flutter drive's -r reinstall.
#
# CRITICAL: appops must NOT run in the post-install window before the package
# manager has registered the new uid — `appops set --uid <pkg>` then fails with
# "No UID for <pkg>" and (previously, swallowed by `|| true`) the app silently
# never got all-files access. Poll until the appop actually reads back "allow".
echo ">>> Granting MANAGE_EXTERNAL_STORAGE (waiting for uid registration)..."
for _ in $(seq 1 15); do
  MSYS_NO_PATHCONV=1 $ADBD shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1
  if MSYS_NO_PATHCONV=1 $ADBD shell appops get --uid "$PKG" MANAGE_EXTERNAL_STORAGE 2>/dev/null \
       | tr -d '\r' | grep -q "MANAGE_EXTERNAL_STORAGE: allow"; then
    echo ">>> MANAGE_EXTERNAL_STORAGE: allow"
    break
  fi
  sleep 1
done

# ── Target list (classified by prerequisite for the summary) ──
# Resolved here (before provisioning) so we only pay for prerequisites the
# selected targets actually need — e.g. a `--only=app_smoke` run must not boot
# and onboard AnkiDroid.
ALL_TARGETS=(
  app_smoke settings_validation navigation_stability home_keyboard
  gamepad_navigation feature_flows
  comprehensive_imports comprehensive_reader_lookup comprehensive_settings
  reader_pagination reader_caret reader_popup_caret reader_computer_use_flow
  image_pause_detection
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

# Only anki_integration needs the (slow) AnkiDroid install + collection
# onboarding. Gate the provisioning on the selected target set.
NEEDS_ANKI=false
for t in "${TARGETS[@]}"; do
  if [ "$t" = anki_integration ]; then
    NEEDS_ANKI=true
    break
  fi
done

# ── Provision external prerequisites (best effort; failures only affect the
#    targets that need them, reported in the summary). ──
ANKI_OK=false
if [ "$NEEDS_ANKI" = true ]; then
  if provision_ankidroid && grant_hibiki_ankidroid_permission; then
    ANKI_OK=true
  else
    echo ">>> WARN: AnkiDroid not fully provisioned — anki_integration may fail." >&2
  fi
else
  echo ">>> Skipping AnkiDroid provisioning (anki_integration not selected)."
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
  # Push to shared /sdcard/Download (NOT the app external-files dir): flutter
  # drive reinstalls the app, which wipes /sdcard/Android/data/<pkg>/, so a file
  # staged there before the run is gone by test time. Shared storage survives
  # reinstall; the app reads it via the MANAGE_EXTERNAL_STORAGE grant above.
  DICT_DEST="/sdcard/Download/test_dict.zip"
  echo ">>> Pushing dictionary fixture ($(basename "$DICT_ZIP")) to $DICT_DEST..."
  # Push from a Windows-form source path (see win_path) under MSYS_NO_PATHCONV.
  if MSYS_NO_PATHCONV=1 $ADBD push "$(win_path "$DICT_ZIP")" "$DICT_DEST" >/dev/null; then
    DICT_OK=true
  fi
else
  echo ">>> WARN: no dictionary zip found under $DICT_DIR — popup_dictionary may fail." >&2
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
