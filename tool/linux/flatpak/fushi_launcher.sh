#!/bin/bash
# Flatpak entry point (`command: fushi`, installed as /app/bin/fushi): starts
# /app/fushi/fushi with the X11 -> Wayland fallback below.
#
# The manifest pins GDK_BACKEND=x11 because the out-of-app floating ball and its
# overlays place their own windows, which Wayland does not allow. On some
# machines Fushi's X11 drawing crashes within a second of the first frame while
# Wayland works (a hybrid Intel + NVIDIA laptop on GNOME, Intel GPU through
# Mesa: docs/bugs, slug flatpak-x11-mesa-crash). When the X11 run dies from a
# crash signal within the first seconds and a Wayland display exists, the same
# command starts again on Wayland, and that build keeps using Wayland from then
# on (no floating ball outside the app). A new build tries X11 again; deleting
# the state file does too.
#
# Temporary compatibility layer: the X11 crash is inside the graphics stack
# (Flutter's X11 path / Mesa), not in Fushi. Remove this wrapper once that crash
# is root-caused and fixed upstream.
#
# Left alone: any GDK_BACKEND other than the manifest's exact `x11` (the user's
# own `flatpak override --env=GDK_BACKEND=...`), sessions without Wayland, and
# Steam Deck Game Mode, which must stay on X11 (linux_steam_shortcut.dart).
set -u

binary="${FUSHI_LAUNCHER_BINARY:-/app/fushi/fushi}"
flatpak_info="${FUSHI_LAUNCHER_FLATPAK_INFO:-/.flatpak-info}"
state_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fushi"
state_file="$state_dir/x11-fallback"
# A crash this soon after launch counts as "X11 drawing does not work here".
startup_window_s=20

if [ "${GDK_BACKEND:-}" != x11 ] || [ -z "${WAYLAND_DISPLAY:-}" ] ||
  [ -n "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]; then
  exec "$binary" "$@"
fi

build_id="$(sed -n 's/^app-commit=//p' "$flatpak_info" 2>/dev/null | head -n 1)"
marker="app-commit=${build_id:-unknown}"

if [ -f "$state_file" ]; then
  if [ "$(head -n 1 "$state_file" 2>/dev/null)" = "$marker" ]; then
    export GDK_BACKEND=wayland
    exec "$binary" "$@"
  fi
  rm -f "$state_file"
fi

# 128 + SIGILL / SIGTRAP / SIGABRT / SIGBUS / SIGFPE / SIGSEGV. Not SIGTERM /
# SIGKILL / SIGINT: those are someone ending the app, not a crash.
is_crash() {
  case "$1" in
    132 | 133 | 134 | 135 | 136 | 139) return 0 ;;
  esac
  return 1
}

# Runs the app with GDK_BACKEND=$1 and the remaining arguments, passing
# termination signals on to it. Sets `status` and `elapsed_s`.
run_app() {
  local backend="$1"
  shift
  local start=$SECONDS
  # `<&0`: a background job's stdin is /dev/null unless redirected.
  GDK_BACKEND="$backend" "$binary" "$@" <&0 &
  local child=$!
  trap 'kill -TERM "$child" 2>/dev/null' TERM
  trap 'kill -INT "$child" 2>/dev/null' INT
  trap 'kill -HUP "$child" 2>/dev/null' HUP
  # A trapped signal makes `wait` return early (status > 128) while the app
  # may still run, so wait until it is gone. Bash keeps a finished child's
  # status, so the last `wait` reports its real exit (127 = an old bash that
  # already dropped it: keep what we have).
  while :; do
    wait "$child"
    status=$?
    if ! kill -0 "$child" 2>/dev/null; then
      wait "$child" 2>/dev/null
      local final=$?
      [ "$final" -ne 127 ] && status=$final
      break
    fi
  done
  trap - TERM INT HUP
  elapsed_s=$((SECONDS - start))
}

run_app x11 "$@"
if is_crash "$status" && [ "$elapsed_s" -lt "$startup_window_s" ]; then
  echo "fushi: the X11 window crashed after ${elapsed_s}s (exit $status);" \
    "starting again on Wayland. Delete $state_file to try X11 again." >&2
  mkdir -p "$state_dir" && printf '%s\n' "$marker" >"$state_file"
  run_app wayland "$@"
  if is_crash "$status" && [ "$elapsed_s" -lt "$startup_window_s" ]; then
    # It crashes on Wayland as well, so X11 was not the problem.
    rm -f "$state_file"
  fi
fi
exit "$status"
