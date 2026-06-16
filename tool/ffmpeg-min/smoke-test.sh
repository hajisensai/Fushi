#!/usr/bin/env bash
# Behavioral contract for Hibiki's minimal desktop FFmpeg.
#
# A full host FFmpeg generates tiny representative inputs. The minimal binary
# must then execute the same argument shapes used by desktop_audio_clipper.dart
# and video_subtitle_source.dart. This keeps the configure allowlist honest:
# a successful compile alone is not sufficient.
set -euo pipefail

FFMPEG_MIN="${FFMPEG_MIN:?set FFMPEG_MIN to the minimal ffmpeg binary}"
FIXTURE_FFMPEG="${FIXTURE_FFMPEG:-ffmpeg}"
WORK="${WORK:-$(mktemp -d)}"
KEEP_WORK="${KEEP_WORK:-0}"

if [ "$KEEP_WORK" != "1" ]; then
  trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"

run() {
  echo "+ $*"
  "$@"
}

assert_nonempty() {
  local path="$1"
  if [ ! -s "$path" ]; then
    echo "[ffmpeg-min-smoke] missing or empty output: $path" >&2
    exit 1
  fi
}

assert_log_contains() {
  local path="$1"
  local pattern="$2"
  if ! grep -Eiq "$pattern" "$path"; then
    echo "[ffmpeg-min-smoke] expected '$pattern' in $path" >&2
    cat "$path" >&2
    exit 1
  fi
}

cat >"$WORK/sub.srt" <<'EOF'
1
00:00:00,100 --> 00:00:01,400
Hibiki minimal FFmpeg smoke test.
EOF

cat >"$WORK/sub.ass" <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.10,0:00:01.40,Default,,0,0,0,,Hibiki ASS smoke test.
EOF

echo "[ffmpeg-min-smoke] generating representative inputs in $WORK"

MP4_FIXTURE="$WORK/h264-movtext.mp4"
MKV_FIXTURE="$WORK/h264-ass.mkv"

# MP4: H.264 + AAC + mov_text, covering the most common video path.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=duration=2:size=160x90:rate=12" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -i "$WORK/sub.srt" \
  -map 0:v -map 1:a -map 2:s \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -c:s mov_text -shortest "$MP4_FIXTURE"

# MKV: H.264 + Opus + ASS, covering Matroska and native subtitle extraction.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=duration=2:size=160x90:rate=12" \
  -f lavfi -i "sine=frequency=660:duration=2" \
  -i "$WORK/sub.ass" \
  -map 0:v -map 1:a -map 2:s \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a libopus -c:s ass -shortest "$MKV_FIXTURE"

# Raw and ASF audio formats explicitly accepted by AudiobookStorage.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=330:duration=2" -c:a ac3 "$WORK/tone.ac3"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=550:duration=2" -c:a eac3 "$WORK/tone.eac3"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=770:duration=2" -c:a wmav2 "$WORK/tone.wma"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=990:duration=2" -c:a pcm_f32le "$WORK/tone.wav"

# M4A files with the common JPEG and PNG attached-cover codecs.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=red:size=64x64:duration=1" \
  -frames:v 1 "$WORK/cover.png"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=880:duration=2" \
  -i "$WORK/cover.png" \
  -map 0:a -map 1:v \
  -c:a aac -c:v mjpeg -disposition:v attached_pic \
  -shortest "$WORK/covered.m4a"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=880:duration=2" \
  -f lavfi -i "color=blue:size=64x64:duration=1" \
  -map 0:a -map 1:v \
  -c:a aac -c:v png -frames:v 1 -disposition:v attached_pic \
  "$WORK/covered-png.m4a"

echo "[ffmpeg-min-smoke] probing and extracting embedded subtitles"
if "$FFMPEG_MIN" -hide_banner -i "$MP4_FIXTURE" \
    >"$WORK/probe.log" 2>&1; then
  echo "[ffmpeg-min-smoke] ffmpeg -i unexpectedly returned success" >&2
  exit 1
fi
assert_log_contains "$WORK/probe.log" "Subtitle: mov_text"

run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -i "$MP4_FIXTURE" -map 0:s:0 "$WORK/movtext.srt"
assert_nonempty "$WORK/movtext.srt"

run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -i "$MKV_FIXTURE" -map 0:s:0 "$WORK/embedded.ass"
assert_nonempty "$WORK/embedded.ass"

echo "[ffmpeg-min-smoke] exporting cue GIF and frame"
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -t 1.000 -i "$MP4_FIXTURE" -an \
  -filter_complex \
  "fps=12,scale=160:-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
  -loop 0 "$WORK/cue.gif"
assert_nonempty "$WORK/cue.gif"

run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -i "$MP4_FIXTURE" -an \
  -frames:v 1 -update 1 "$WORK/frame.jpg"
assert_nonempty "$WORK/frame.jpg"

echo "[ffmpeg-min-smoke] exporting sentence audio"
for input in \
  "$MP4_FIXTURE" \
  "$MKV_FIXTURE" \
  "$WORK/tone.ac3" \
  "$WORK/tone.eac3" \
  "$WORK/tone.wma" \
  "$WORK/tone.wav"; do
  stem="$(basename "$input")"
  run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
    -ss 0.100 -t 0.800 -i "$input" -vn -c:a aac "$WORK/$stem.aac"
  assert_nonempty "$WORK/$stem.aac"
done

echo "[ffmpeg-min-smoke] extracting attached cover"
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -i "$WORK/covered.m4a" -an -map 0:v:disp:attached_pic \
  -frames:v 1 -update 1 "$WORK/cover.jpg"
assert_nonempty "$WORK/cover.jpg"
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -i "$WORK/covered-png.m4a" -an -map 0:v:disp:attached_pic \
  -frames:v 1 -update 1 "$WORK/cover-png.jpg"
assert_nonempty "$WORK/cover-png.jpg"

# Validate generated outputs with the full host build.
for output in \
  "$WORK/cue.gif" \
  "$WORK/frame.jpg" \
  "$MP4_FIXTURE.aac" \
  "$MKV_FIXTURE.aac" \
  "$WORK/tone.ac3.aac" \
  "$WORK/tone.eac3.aac" \
  "$WORK/tone.wma.aac" \
  "$WORK/tone.wav.aac" \
  "$WORK/cover.jpg" \
  "$WORK/cover-png.jpg"; do
  run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -i "$output" -f null -
done

echo "[ffmpeg-min-smoke] PASS"
