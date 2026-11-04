#!/usr/bin/env bash
# Drives a running Fushi (Linux) through fushi_cli with the dummy data.
# Each step prints "STEP <name> exit=<n>" followed by its (truncated) output.
cd "${APPDIR:-$HOME/fushi-test/fushi-3.3.0-linux-x64}"
D="${DUMMY:-$HOME/fushi-test/dummy}"
cli() { ./fushi_cli "$@"; }
step() {
  local name="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  echo "STEP $name exit=$rc"
  printf '%s\n' "$out" | head -n "${LINES_MAX:-12}" | cut -c1-220
  echo
  if [ -n "${SHOT_DIR:-}" ]; then
    sleep 1
    # Wayland desktops (KDE / Steam Deck Desktop Mode) cannot be grabbed with xwd.
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v spectacle >/dev/null; then
      timeout 20 spectacle -b -n -f -o "$SHOT_DIR/$name.png" >/dev/null 2>&1
    else
      xwd -root -silent | convert xwd:- "$SHOT_DIR/$name.png" 2>/dev/null
    fi
  fi
}

step status            cli status
step dict-import       cli dict import "$D/dummy_dict.zip"
sleep 3
step dict-ls           cli dict ls
step dict-search       cli dict search 日本語
step dict-search-infl  cli dict search 勉強します
step lib-import        cli library import "$D/dummy_book.epub" "$D/dummy_doc.pdf" "$D/dummy_manga.cbz" "$D/dummy_clip.mp4"
sleep 5
LINES_MAX=30 step lib-ls cli library ls
step srs-stats         cli srs stats
step stats             cli stats --help
