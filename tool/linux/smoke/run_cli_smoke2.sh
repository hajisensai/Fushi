#!/usr/bin/env bash
# Part 2: open each item, reader / player / music / anki checks, screenshots via xwd if present.
cd "${APPDIR:-$HOME/fushi-test/fushi-3.3.0-linux-x64}"
D="${DUMMY:-$HOME/fushi-test/dummy}"
cli() { ./fushi_cli "$@"; }
step() {
  local name="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  echo "STEP $name exit=$rc"
  printf '%s\n' "$out" | head -n "${LINES_MAX:-10}" | cut -c1-220
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

step epub-open     cli library open 'book:テスト本'
sleep 6
step epub-status   cli reader status
step epub-next     cli reader next
sleep 1
step epub-status2  cli reader status
step epub-goto-ch2 cli reader goto --chapter 2
sleep 2
step epub-status3  cli reader status
step lookup-popup  cli lookup 猫
sleep 3

step pdf-open      cli library open book:dummy_doc
sleep 5
step pdf-status    cli reader status
step pdf-goto3     cli reader goto --page 3
sleep 1
step pdf-status2   cli reader status

step manga-open    cli library open book:dummy_manga
sleep 5
step manga-status  cli reader status
step manga-next    cli reader next
sleep 1
step manga-status2 cli reader status

VKEY="$(./fushi_cli library ls 2>/dev/null | awk '/^video:/{print $1; exit}')"
echo "video key: $VKEY"
step video-open    cli library open "$VKEY"
sleep 6
step video-player  cli video player
step video-subimp  cli video sub-import "$D/dummy_clip.ja.srt"
sleep 2
step video-subs    cli video subs
step play-seek     cli play seek 2
sleep 1
step play-status   cli play status
step play-pause    cli play pause

step music-add     cli music source-add "$D"
sleep 5
step music-tracks  cli music tracks
step anki-status   cli anki status
step mods          cli module --help
step nav-home      cli nav --help
