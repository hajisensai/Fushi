#!/usr/bin/env bash
# dist_test worker: compile check of this checkout, for tool/heavy.dart
# --check-only (tool/dist_test.dart --build).
#   bash fushi/tool/dist_test/worker_build.sh flutter <apk|appbundle|windows|macos> [options]
#   bash fushi/tool/dist_test/worker_build.sh gradle <task...> [-Ptarget-platform=...]
# Targets, options and tasks are checked against the same fixed lists as
# test_flow/dist_plan.dart (distBuildOf); anything else is refused (exit 2).
# Nothing built here leaves this machine: stdout is the build's log, the exit
# code the build's. Exit 78: part of the toolchain is missing, nothing was
# built (the coordinator tries another machine; it is not a red build).
#
# An Android release build needs a signing key and the app's Rust libraries
# for every target ABI (app/build.gradle refuses to build without them). The
# libraries are built here (cached per crate source and ABI); the key is a
# throwaway one made here, so a compile check never needs the real one.
set -uo pipefail
cd "$(dirname "$0")/../../.."
root=$(pwd)
# .git/fushi-dist in a worker checkout; also right in a git worktree.
state="$(git rev-parse --absolute-git-dir)/fushi-dist"
mkdir -p "$state"
EX_TOOLCHAIN=78

refuse() { echo "error: $*" >&2; exit 2; }
lack() { echo "toolchain: $*" >&2; exit "$EX_TOOLCHAIN"; }

windows=
case "$(uname -s)" in MINGW*|MSYS*) windows=1 ;; esac

tool=${1:-}
[ $# -gt 0 ] && shift
platforms=
release=
case "$tool" in
  flutter)
    target=${1:-}
    [ $# -gt 0 ] && shift
    case "$target" in
      apk|appbundle) need=android ;;
      windows) need=windows ;;
      macos) need=macos ;;
      *) refuse "bad build target '$target'" ;;
    esac
    mode=--release
    for a in "$@"; do
      case "$a" in
        --debug|--profile|--release) mode=$a ;;
        --tree-shake-icons|--no-tree-shake-icons) ;;
        --split-per-abi) [ "$target" = apk ] || refuse "rejected build option '$a'" ;;
        --target-platform=*)
          [ "$need" = android ] || refuse "rejected build option '$a'"
          platforms=${a#--target-platform=} ;;
        *) refuse "rejected build option '$a'" ;;
      esac
    done
    [ "$target" != macos ] || [ "$mode" = --debug ] ||
      refuse "macos builds are checked in --debug only"
    [ "$mode" = --release ] && release=1
    ;;
  gradle)
    need=android
    [ $# -gt 0 ] || refuse "usage: worker_build.sh gradle <task...>"
    for a in "$@"; do
      case "$a" in
        -Ptarget-platform=*) platforms=${a#-Ptarget-platform=} ;;
        *)
          printf '%s\n' "$a" |
            grep -Eq '^(:app:)?(assemble|bundle)(Debug|Profile|Release)$' ||
            refuse "rejected gradle task '$a'"
          case "$a" in *Release) release=1 ;; esac ;;
      esac
    done
    ;;
  *) refuse "usage: worker_build.sh flutter|gradle ..." ;;
esac
if [ -n "$platforms" ]; then
  printf '%s\n' "$platforms" |
    grep -Eq '^android-(arm|arm64|x64)(,android-(arm|arm64|x64))*$' ||
    refuse "rejected target platforms '$platforms'"
fi

# ---- toolchain ----
android_sdk() {
  local d local_appdata=
  [ -n "${LOCALAPPDATA:-}" ] && local_appdata=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" \
           "$HOME/Android/Sdk" "${local_appdata:+$local_appdata/Android/Sdk}"; do
    if [ -n "$d" ] && [ -d "$d/platforms" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

# A JDK's bin directory with keytool: JAVA_HOME, PATH, or Android Studio's.
jdk_bin() {
  local d
  for d in "${JAVA_HOME:+$JAVA_HOME/bin}" \
           "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin" \
           "/c/Program Files/Android/Android Studio/jbr/bin" \
           "$HOME/android-studio/jbr/bin"; do
    if [ -n "$d" ] && { [ -x "$d/keytool" ] || [ -x "$d/keytool.exe" ]; }; then
      echo "$d"
      return 0
    fi
  done
  command -v keytool > /dev/null 2>&1 && dirname "$(command -v keytool)"
}

case "$need" in
  windows)
    [ -n "$windows" ] || lack "a Windows build needs a Windows machine"
    vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    [ -x "$vswhere" ] &&
      [ -n "$("$vswhere" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath 2>/dev/null)" ] ||
      lack "Visual Studio with the C++ desktop workload"
    # CMake reaches each plugin through ephemeral/.plugin_symlinks. The
    # Flutter tool makes directory symlinks there, which on wight-win
    # (2026-10-30) no native program on the worker account could follow, so
    # every build died in CMake (Git Bash could: it resolves links itself).
    # plugin_junctions.dart puts junctions there instead; make one here and
    # go through it with cmd, as CMake would.
    probe="$state/junction-probe"
    cmd.exe //c rmdir "$(cygpath -w "$probe")" > /dev/null 2>&1
    mkdir -p "$state/junction-probe-target" &&
      : > "$state/junction-probe-target/ok"
    cmd.exe //c mklink //J "$(cygpath -w "$probe")" \
      "$(cygpath -w "$state/junction-probe-target")" > /dev/null 2>&1 ||
      lack "this account cannot make junctions, which Windows builds with plugins need"
    followed=
    cmd.exe //c "if exist $(cygpath -w "$probe")\\ok (exit 0) else (exit 1)" \
      > /dev/null 2>&1 && followed=1
    cmd.exe //c rmdir "$(cygpath -w "$probe")" > /dev/null 2>&1
    [ -n "$followed" ] ||
      lack "programs on this account cannot go through junctions, which Windows builds with plugins need"
    ;;
  macos)
    [ "$(uname -s)" = Darwin ] || lack "a macOS build needs a Mac"
    xcodebuild -version > /dev/null 2>&1 || lack "Xcode"
    command -v pod > /dev/null 2>&1 || lack "CocoaPods"
    ;;
  android)
    sdk=$(android_sdk) || lack "the Android SDK (ANDROID_HOME)"
    export ANDROID_HOME="$sdk"
    ndk_version=$(sed -n "s/^[[:space:]]*ndkVersion[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
      fushi/android/app/build.gradle | head -1)
    ndk="$sdk/ndk/$ndk_version"
    [ -n "$ndk_version" ] && [ -d "$ndk" ] || lack "Android NDK $ndk_version"
    cargo ndk --version > /dev/null 2>&1 || lack "cargo-ndk (cargo install cargo-ndk)"
    jdk=$(jdk_bin) || lack "a JDK (JAVA_HOME or Android Studio's)"
    [ -z "${JAVA_HOME:-}" ] && export JAVA_HOME="$(dirname "$jdk")"
    PATH="$jdk:$PATH"
    ;;
esac

# Heartbeat of the checkout lock and the pid files worker_kill.sh reads, as in
# worker_run.sh.
(while sleep 60; do touch -c "$state/lock"; done) > /dev/null 2>&1 < /dev/null &
heartbeat=$!
pid=
kill_tree() {
  if [ -n "$windows" ]; then
    local winpid
    winpid=$(cat "/proc/$1/winpid" 2>/dev/null) &&
      taskkill //F //T //PID "$winpid" > /dev/null 2>&1
    kill -TERM "$1" 2>/dev/null || true
    return
  fi
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}
trap 'kill "$heartbeat" 2>/dev/null; [ -n "$pid" ] && kill_tree "$pid"; rm -f "$state/run.pid" "$state/runner.pid"; exit 143' TERM INT HUP
touch -c "$state/lock" 2>/dev/null
echo "$$" > "$state/runner.pid"

# Everything goes to a file, printed at the end: Gradle and the Flutter tool
# leave daemons behind that would inherit stdout and hold the ssh channel
# open forever.
log="$state/build.log"
: > "$log"
run_child() {
  "$@" >> "$log" 2>&1 < /dev/null &
  pid=$!
  echo "$pid" > "$state/run.pid"
  wait "$pid"
}
finish() {
  if [ "$need" = android ]; then
    # The Gradle daemon would sit on the owner's memory for hours.
    if [ -n "$windows" ]; then
      (cd fushi/android && cmd.exe //c gradlew.bat --stop) > /dev/null 2>&1
    else
      (cd fushi/android && sh ./gradlew --stop) > /dev/null 2>&1
    fi
  fi
  kill "$heartbeat" 2>/dev/null
  rm -f "$state/run.pid" "$state/runner.pid"
  cat "$log"
  exit "$1"
}

if [ "$need" = android ]; then
  # The Rust libraries app/build.gradle requires for each target ABI.
  abis=
  for p in $(printf '%s\n' "${platforms:-android-arm,android-arm64,android-x64}" | tr ',' ' '); do
    case "$p" in
      android-arm) abis="$abis armeabi-v7a" ;;
      android-arm64) abis="$abis arm64-v8a" ;;
      android-x64) abis="$abis x86_64" ;;
    esac
  done
  for crate in fushi_compute fushi_rwkv fushi_music fushi_corpus fushi_web_core; do
    key="$(git rev-parse "HEAD:native/$crate")$abis"
    stamp="$state/android-$crate.key"
    have=1
    for abi in $abis; do
      [ -n "$(ls "native/$crate/prebuilt/android/$abi" 2>/dev/null)" ] || have=
    done
    if [ "$(cat "$stamp" 2>/dev/null || true)" = "$key" ] && [ -n "$have" ]; then
      echo "==> native/$crate (android:$abis) unchanged" >> "$log"
      continue
    fi
    echo "==> build native/$crate (android:$abis)" >> "$log"
    # shellcheck disable=SC2086 # the ABI list is split on purpose
    run_child bash "native/$crate/build_android_so.sh" "$ndk" $abis
    status=$?
    [ "$status" -eq 0 ] || finish "$status"
    echo "$key" > "$stamp"
  done
  if [ -n "$release" ]; then
    # A throwaway signing key; one already here that is not ours is left
    # alone.
    props=fushi/android/key.properties
    jks=fushi/android/dist-check.jks
    marker='# fushi dist_test throwaway key'
    if [ ! -f "$props" ] || grep -qF "$marker" "$props"; then
      if [ ! -f "$props" ] || [ ! -f "$jks" ]; then
        rm -f "$jks"
        pass=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
        keytool -genkeypair -keystore "$jks" -storetype PKCS12 \
          -storepass "$pass" -keypass "$pass" -alias dist -keyalg RSA \
          -keysize 2048 -validity 10000 \
          -dname "CN=fushi dist_test throwaway key" >> "$log" 2>&1 ||
          lack "keytool could not make a throwaway key"
        printf '%s: a compile check only, never a release\nstoreFile=dist-check.jks\nstorePassword=%s\nkeyAlias=dist\nkeyPassword=%s\n' \
          "$marker" "$pass" "$pass" > "$props"
      fi
    fi
  fi
fi

links=fushi/windows/flutter/ephemeral/.plugin_symlinks
if [ "$need" = windows ]; then
  echo "==> plugin junctions" >> "$log"
  dart fushi/tool/dist_test/plugin_junctions.dart fushi >> "$log" 2>&1 ||
    finish 1
fi

case "$tool" in
  flutter)
    cd fushi && run_child flutter build "$target" --no-pub "$@" ;;
  gradle)
    # Gradle reads flutter.sdk (and the generated plugin settings) from what
    # the Flutter tool writes.
    (cd fushi && flutter build apk --config-only --no-pub) >> "$log" 2>&1 ||
      finish 1
    cd fushi/android || finish 1
    if [ -n "$windows" ]; then
      run_child cmd.exe //c gradlew.bat "$@"
    else
      run_child sh ./gradlew "$@"
    fi ;;
esac
status=$?
cd "$root" || true
if [ "$status" -ne 0 ] && [ "$need" = windows ]; then
  # The plugin links as Windows sees them (Git Bash resolves links itself, so
  # only cmd shows whether native programs like CMake can go through them).
  {
    echo "==> plugin links after the build"
    cmd.exe //c "chcp 65001 > nul & dir /AL $(cygpath -w "$links")" 2>&1 |
      grep '<' | head -3
    for l in "$links"/*; do
      cmd.exe //c "if exist $(cygpath -w "$l")\\windows (exit 0) else (exit 1)" \
        > /dev/null 2>&1 &&
        echo "cmd can go through $(basename "$l")" ||
        echo "cmd cannot go through $(basename "$l")"
      break
    done
  } >> "$log" 2>&1
fi
finish "$status"
