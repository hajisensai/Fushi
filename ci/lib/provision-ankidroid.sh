#!/usr/bin/env bash
# Shared AnkiDroid provisioning for Hibiki integration tests.
#
# Sourced by ci/anki-integration-test.sh and ci/integration-test.sh so the
# "install AnkiDroid + create a collection + grant Hibiki the API permission"
# recipe lives in exactly one place (DRY).
#
# WHY THIS IS A FIXTURE STEP, NOT A PRODUCT WORKAROUND
# The AnkiDroid API is gated by the *dangerous* permission
#   com.ichi2.anki.permission.READ_WRITE_DATABASE
# which Android grants only after the user taps "Allow" on AnkiDroid's runtime
# dialog. Hibiki requests it correctly at runtime (AnkiChannelHandler.java
# ankiDroid.requestPermission(...)), but an automated `flutter drive` run
# installs the app fresh and cannot tap that system dialog. We reproduce the
# *granted* state deterministically: pre-install the APK with `adb install -g`
# (grant all runtime perms = the user tapping Allow); flutter drive's `-r`
# reinstall preserves the grant for the instrumented run.
#
# Required env (set by the caller before sourcing):
#   ADBD       full "adb -s <serial>" command
#   PKG        Hibiki application id (app.hibiki.reader)
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
    local tmp_anki="$REPO_ROOT/hibiki/.anki_apk_download.apk"
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
  # AnkiDroid 22.x auto-creates a default collection on its first launch — no
  # onboarding tap is required. We just launch it, let it settle, restart once
  # (the collection is flushed to disk on a clean stop/relaunch), then verify the
  # file landed. The `test -f $ANKI_COLLECTION` check below is the real gate: if
  # the collection still is not there, return 1 so the caller reports
  # anki_integration as failed without aborting the whole run.
  if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $ANKI_COLLECTION" >/dev/null 2>&1; then
    echo ">>> No AnkiDroid collection; running first-launch onboarding..."
    MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 6
    MSYS_NO_PATHCONV=1 $ADBD shell am force-stop "$ANKI_PKG" || true
    MSYS_NO_PATHCONV=1 $ADBD shell monkey -p "$ANKI_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 6
    if ! MSYS_NO_PATHCONV=1 $ADBD shell "test -f $ANKI_COLLECTION" >/dev/null 2>&1; then
      echo ">>> WARN: AnkiDroid collection not created automatically." >&2
      return 1
    fi
  fi
  echo ">>> AnkiDroid collection present."
  return 0
}

# Grant Hibiki the AnkiDroid API permission and verify it stuck. Assumes the
# Hibiki APK is already installed (with -g). Returns 0 if granted=true.
grant_hibiki_ankidroid_permission() {
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
