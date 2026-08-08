#!/usr/bin/env bash
# Shared AnkiDroid provisioning for Fushi integration tests.
#
# Sourced by ci/anki-integration-test.sh and ci/integration-test.sh so the
# "install AnkiDroid + create a collection + grant Fushi the API permission"
# recipe lives in exactly one place (DRY).
#
# WHY THIS IS A FIXTURE STEP, NOT A PRODUCT WORKAROUND
# The AnkiDroid API is gated by the *dangerous* permission
#   com.ichi2.anki.permission.READ_WRITE_DATABASE
# which Android grants only after the user taps "Allow" on AnkiDroid's runtime
# dialog. Fushi requests it correctly at runtime (AnkiChannelHandler.java
# ankiDroid.requestPermission(...)), but an automated `flutter drive` run
# installs the app fresh and cannot tap that system dialog. We reproduce the
# *granted* state deterministically: pre-install the APK with `adb install -g`
# (grant all runtime perms = the user tapping Allow); flutter drive's `-r`
# reinstall preserves the grant for the instrumented run.
#
# Required env (set by the caller before sourcing):
#   ADBD       full "adb -s <serial>" command
#   PKG        Fushi application id (app.fushi.reader)
# Optional:
#   ANKI_APK_URL  override the AnkiDroid APK mirror

ANKI_PKG="com.ichi2.anki"
ANKI_PERM="com.ichi2.anki.permission.READ_WRITE_DATABASE"
ANKI_COLLECTION="/storage/emulated/0/AnkiDroid/collection.anki2"
# F-Droid mirror APK that is reachable from CN (github/cloudflare are bot-gated).
ANKI_APK_URL="${ANKI_APK_URL:-https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo/com.ichi2.anki_22400300.apk}"

# Convert an MSYS path (/d/foo) to a Windows path (D:/foo) so the native
# adb.exe can stat a local install/push source. Under MSYS_NO_PATHCONV=1 a
# /d/... source reaches adb verbatim and fails to stat ("failed to stat"); a
# pre-converted D:/... source is valid for native adb.exe. On Linux CI cygpath
# is absent and the path is already POSIX, so the sed fallback is a no-op for
# non-drive paths. Lives here (the shared lib) so every caller that sources this
# file gets it — ci/integration-test.sh re-exports the same helper for its own
# dictionary push.
win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    echo "$1" | sed -E 's#^/([a-zA-Z])/#\U\1:/#'
  fi
}

# Ensure AnkiDroid is installed with a usable collection. Returns 0 on success,
# 1 if the collection could not be created automatically (caller decides whether
# that is fatal — for the all-targets runner it just means anki_integration
# will be reported as failed, not that the whole run aborts).
provision_ankidroid() {
  # 1. Install AnkiDroid if absent.
  if ! MSYS_NO_PATHCONV=1 $ADBD shell pm path "$ANKI_PKG" >/dev/null 2>&1; then
    echo ">>> AnkiDroid not installed; downloading from mirror..."
    local tmp_anki="$REPO_ROOT/fushi/.anki_apk_download.apk"
    if ! curl -L --ssl-no-revoke -o "$tmp_anki" "$ANKI_APK_URL"; then
      echo ">>> WARN: AnkiDroid download failed — anki_integration will fail." >&2
      rm -f "$tmp_anki"
      return 1
    fi
    MSYS_NO_PATHCONV=1 $ADBD install "$(win_path "$tmp_anki")"
    rm -f "$tmp_anki"
  else
    echo ">>> AnkiDroid already installed."
  fi

  # 2. Storage permission + notifications (best effort).
  MSYS_NO_PATHCONV=1 $ADBD shell appops set "$ANKI_PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  MSYS_NO_PATHCONV=1 $ADBD shell pm grant "$ANKI_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

  # 3. Ensure a collection file exists (first-launch onboarding).
  # AnkiDroid 22.4.3 does NOT silently auto-create a collection: a fresh install
  # lands on IntroductionActivity with a "Get started" button that must be
  # activated before DeckPicker runs and writes collection.anki2. A bare `monkey`
  # LAUNCHER intent only re-surfaces that intro screen — it does not dismiss it —
  # so on API 34 the collection never appears without one interaction. We (a)
  # launch the intro explicitly, (b) best-effort advance it with focus-traversal
  # + Enter (no fragile screen coordinates), then (c) verify. The
  # `test -f $ANKI_COLLECTION` check is the real gate: if it is still missing we
  # FAIL LOUDLY with the one manual step, rather than silently pretending
  # AnkiDroid is ready (return 1 so the caller reports anki_integration failed
  # without aborting the whole run).
  if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $ANKI_COLLECTION" >/dev/null 2>&1; then
    echo ">>> No AnkiDroid collection; running first-launch onboarding..."
    # Launch the intro directly (monkey only ever re-surfaces this same screen).
    MSYS_NO_PATHCONV=1 $ADBD shell am start -n "$ANKI_PKG/.IntroductionActivity" >/dev/null 2>&1 \
      || MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
      || true
    sleep 4
    # Best-effort, coordinate-free advance: move focus onto "Get started" and
    # activate it with Enter. If the build ignores these keyevents the verify
    # below still gates the truth, so this can only help, never corrupt state.
    MSYS_NO_PATHCONV=1 $ADBD shell input keyevent KEYCODE_TAB >/dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 $ADBD shell input keyevent KEYCODE_TAB >/dev/null 2>&1 || true
    MSYS_NO_PATHCONV=1 $ADBD shell input keyevent KEYCODE_ENTER >/dev/null 2>&1 || true
    sleep 4
    # A clean stop/relaunch flushes any freshly-created collection to disk.
    MSYS_NO_PATHCONV=1 $ADBD shell am force-stop "$ANKI_PKG" || true
    MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 4
    if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $ANKI_COLLECTION" >/dev/null 2>&1; then
      echo ">>> FAIL: AnkiDroid ($ANKI_PKG) still has no collection at" >&2
      echo ">>>       $ANKI_COLLECTION. AnkiDroid 22.4.3 blocks automated" >&2
      echo ">>>       onboarding at IntroductionActivity — its 'Get started'" >&2
      echo ">>>       button could not be activated headlessly on this image." >&2
      echo ">>>       ONE-TIME manual step: open AnkiDroid on the emulator, tap" >&2
      echo ">>>       'Get started' once, then re-run. Verify it took with:" >&2
      echo ">>>         $ADBD shell test -f $ANKI_COLLECTION && echo OK" >&2
      return 1
    fi
  fi
  echo ">>> AnkiDroid collection present."
  return 0
}

# Grant Fushi the AnkiDroid API permission and verify it stuck. Assumes the
# Fushi APK is already installed (with -g). Returns 0 if granted=true.
grant_fushi_ankidroid_permission() {
  MSYS_NO_PATHCONV=1 $ADBD shell pm grant "$PKG" "$ANKI_PERM" >/dev/null 2>&1 || true
  local granted
  granted=$(MSYS_NO_PATHCONV=1 $ADBD shell dumpsys package "$PKG" 2>/dev/null | grep "$ANKI_PERM: granted=true" || true)
  if [ -z "$granted" ]; then
    echo ">>> WARN: could not grant $ANKI_PERM to $PKG." >&2
    return 1
  fi
  echo ">>> $ANKI_PERM granted=true."
  return 0
}
