#!/usr/bin/env bash
# Behavioral contract for Fushi's minimal desktop FFmpeg.
#
# A full host FFmpeg generates tiny representative inputs. The minimal binary
# must then execute the same argument shapes used by desktop_audio_clipper.dart
# and video_subtitle_source.dart. This keeps the configure allowlist honest:
# a successful compile alone is not sufficient.
set -euo pipefail

FFMPEG_MIN="${FFMPEG_MIN:?set FFMPEG_MIN to the minimal ffmpeg binary}"
# BUG-1420: ffprobe ships next to ffmpeg in every desktop bundle and has its own
# consumers (embedded subtitle fonts, audio container tags). Default to the
# sibling of FFMPEG_MIN so callers that only set FFMPEG_MIN still exercise it.
FFPROBE_MIN="${FFPROBE_MIN:-$(dirname "$FFMPEG_MIN")/$(basename "$FFMPEG_MIN" | sed 's/^ffmpeg/ffprobe/')}"
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
Fushi minimal FFmpeg smoke test.
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
Dialogue: 0,0:00:00.10,0:00:01.40,Default,,0,0,0,,Fushi ASS smoke test.
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

# 制卡封面动图的另外两种格式（默认已是 AVIF）。参数形态与
# desktop_audio_clipper.dart 的 buildFfmpegClipAnimatedArgs 一致：真彩格式不需要
# 调色板，滤镜退化成单趟 fps,scale，编码器各自显式指定。
# 少了 libsvtav1 / libwebp / avif / webp muxer 中任何一项，这两条就会当场失败——
# 「编译过了」不等于「用户选的格式能产出」，Dart 侧的 fail-open 会把这种缺失
# 静默降级成 GIF，只有这里能抓住。
echo "[ffmpeg-min-smoke] exporting cue WebP and AVIF"
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -t 1.000 -i "$MP4_FIXTURE" -an \
  -vf "fps=12,scale=160:-2:flags=lanczos" \
  -c:v libwebp_anim -lossless 0 -q:v 75 -pix_fmt yuv420p \
  -loop 0 "$WORK/cue.webp"
assert_nonempty "$WORK/cue.webp"

run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -t 1.000 -i "$MP4_FIXTURE" -an \
  -vf "fps=12,scale=160:-2:flags=lanczos" \
  -c:v libsvtav1 -preset 8 -crf 32 -pix_fmt yuv420p \
  -loop 0 "$WORK/cue.avif"
assert_nonempty "$WORK/cue.avif"

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

echo "[ffmpeg-min-smoke] synthesizing audiobook clip video (loop PNG + audio -> mov)"
# TODO-1096: mirror buildFfmpegImageAudioToVideoArgs
# (fushi/lib/src/media/audiobook/audiobook_clip_export.dart). The clip export
# feeds a single text PNG as a looping video stream (`-loop 1 -i clip.png`) and
# muxes mjpeg video + aac audio into a .mov. Reading the named PNG needs the
# image2 demuxer; a missing image2 makes ffmpeg exit -1094995529
# (AVERROR_INVALIDDATA, "Invalid data found when processing input"). Exercise the
# real binary so a dropped image2 demuxer fails the build, not the user.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y  -f lavfi -i "color=green:size=64x64:duration=1"  -frames:v 1 "$WORK/clip-text.png"
run "$FFMPEG_MIN" -hide_banner -loglevel error -y  -loop 1 -i "$WORK/clip-text.png"  -i "$WORK/tone.wav"  -c:v mjpeg -pix_fmt yuvj420p -r 12  -vf "scale=64:64:force_original_aspect_ratio=decrease,pad=64:64:(ow-iw)/2:(oh-ih)/2:color=black"  -c:a aac -shortest "$WORK/clip.mov"
assert_nonempty "$WORK/clip.mov"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -i "$WORK/clip.mov" -f null -

echo "[ffmpeg-min-smoke] probing audio RMS energy envelope (aresample/asetnsamples/astats/ametadata)"
# TODO-1096: mirror buildFfmpegPcmEnvelopeArgs
# (fushi/lib/src/media/video/audio_energy_probe.dart). Subtitle auto-align
# (TODO-701) probes per-frame RMS energy through the SAME bundled ffmpeg via
# `-af aresample=R,asetnsamples=n=N:p=0,astats=metadata=1:reset=1,ametadata=print:key=...`
# `-f null -`. A minimal build missing asetnsamples/astats/ametadata parses
# the filterchain unsuccessfully → empty envelope, silently breaking auto-align.
# Exercise the real binary so a dropped filter fails the build, not the user.
# The probe discards output via `-f null -`; a minimal build missing the null
# muxer fails with "Requested output format 'null' is not known" before any
# filter runs. Assert the muxer exists up front so a dropped null (or mov)
# fails loudly here instead of silently breaking runtime auto-align.
"$FFMPEG_MIN" -hide_banner -muxers > "$WORK/muxers.txt" 2>&1
if ! grep -qw null "$WORK/muxers.txt" || ! grep -qw mov "$WORK/muxers.txt"; then
  echo "MISSING MUXER (need null + mov for energy probe / clip synth):"
  cat "$WORK/muxers.txt"
  exit 1
fi
# The null muxer's default audio encoder is pcm_s16le; `-f null -` opens the
# null output with it. A build carrying the null muxer but missing the
# pcm_s16le encoder fails with "Default encoder for format null (codec
# pcm_s16le) ... Encoder not found" (TODO-1096). Assert it exists up front so a
# dropped encoder fails loudly here instead of at runtime auto-align.
"$FFMPEG_MIN" -hide_banner -encoders > "$WORK/encoders.txt" 2>&1
if ! grep -qw pcm_s16le "$WORK/encoders.txt"; then
  echo "MISSING ENCODER (need pcm_s16le for the -f null energy probe):"
  cat "$WORK/encoders.txt"
  exit 1
fi
echo "+ $FFMPEG_MIN -hide_banner -nostats -i $WORK/tone.wav -af aresample=8000,asetnsamples=n=400:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level -f null -"
# Capture stderr so a probe failure shows the real ffmpeg error, not just an
# exit code (this is the app's literal call: -f null - to read astats metadata).
if ! "$FFMPEG_MIN" -hide_banner -nostats -i "$WORK/tone.wav" -af "aresample=8000,asetnsamples=n=400:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level" -f null - >"$WORK/rms.log" 2>&1; then
  echo "[smoke] energy probe FAILED:"
  cat "$WORK/rms.log"
  exit 1
fi
assert_log_contains "$WORK/rms.log" "lavfi.astats.Overall.RMS_level"

echo "[ffmpeg-min-smoke] verifying network protocols (http/https/tls for YouTube mining)"
# TODO-1214: YouTube/remote mining feeds ffmpeg an http(s) googlevideo stream and
# adds -reconnect* input options (buildFfmpegRemoteInputArgs,
# fushi/lib/src/utils/misc/desktop_audio_clipper.dart). A build without
# --enable-network has NO http/https protocol, so opening the URL and the
# -reconnect option both fail (AVERROR_OPTION_NOT_FOUND). Assert the protocols
# exist up front so a dropped --enable-network fails loudly here, not at runtime.
"$FFMPEG_MIN" -hide_banner -protocols > "$WORK/protocols.txt" 2>&1
for proto in http https tls tcp; do
  if ! grep -qw "$proto" "$WORK/protocols.txt"; then
    echo "MISSING PROTOCOL (need $proto for YouTube/remote mining, TODO-1214):"
    cat "$WORK/protocols.txt"
    exit 1
  fi
done

echo "[ffmpeg-min-smoke] verifying libx264 encoder + mp4 clip export (TODO-1257)"
# TODO-1257: clip export writes an H.264 .mp4 (universally openable in any
# player/browser). Needs the libx264 encoder + mp4 muxer. Assert the encoder is
# present, then actually re-encode to a real .mp4 and validate it with the
# fixture build so a dropped libx264/mp4 fails the build, not the user.
"$FFMPEG_MIN" -hide_banner -encoders > "$WORK/encoders2.txt" 2>&1
if ! grep -qw libx264 "$WORK/encoders2.txt"; then
  echo "MISSING ENCODER (need libx264 for h264 mp4 clip export, TODO-1257):"
  cat "$WORK/encoders2.txt"
  exit 1
fi
"$FFMPEG_MIN" -hide_banner -muxers > "$WORK/muxers2.txt" 2>&1
if ! grep -qw mp4 "$WORK/muxers2.txt"; then
  echo "MISSING MUXER (need mp4 for h264 clip export, TODO-1257):"
  cat "$WORK/muxers2.txt"
  exit 1
fi
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -t 1.000 -i "$MP4_FIXTURE" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -movflags +faststart \
  "$WORK/clip.mp4"
assert_nonempty "$WORK/clip.mp4"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -i "$WORK/clip.mp4" -f null -

echo "[ffmpeg-min-smoke] verifying movtext encoder + soft-subtitle clip mux"
# Clip export muxes the subtitle the user is actually watching into the exported
# .mp4 as a soft subtitle stream. The cues live in Dart memory (Fushi renders
# subtitles in a Flutter overlay, not via libmpv), so they are written out as a
# temporary SRT and fed to ffmpeg as a second input -- which needs the srt
# demuxer + subrip decoder on the way in, and the movtext ENCODER on the way out
# (ISO-BMFF only accepts 3GPP Timed Text). The movtext *decoder* has always been
# enabled for reading embedded mp4 subs; the encoder is a separate switch and was
# missing, which made every export silently fall back to a subtitle-less clip.
"$FFMPEG_MIN" -hide_banner -encoders > "$WORK/encoders3.txt" 2>&1
if ! grep -qw mov_text "$WORK/encoders3.txt"; then
  echo "MISSING ENCODER (need movtext to mux soft subtitles into exported mp4 clips):"
  cat "$WORK/encoders3.txt"
  exit 1
fi
cat > "$WORK/clipsub.srt" <<'SRT'
1
00:00:00,100 --> 00:00:00,900
テスト字幕
SRT
run "$FFMPEG_MIN" -hide_banner -loglevel error -y \
  -ss 0.100 -t 1.000 -i "$MP4_FIXTURE" \
  -i "$WORK/clipsub.srt" \
  -map 0:v:0 -map '0:a?' -map 1:s:0 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s mov_text \
  -movflags +faststart \
  "$WORK/clip-subbed.mp4"
assert_nonempty "$WORK/clip-subbed.mp4"
# The subtitle stream must survive into the output, not just "ffmpeg exited 0".
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -i "$WORK/clip-subbed.mp4" -map 0:s:0 "$WORK/clip-subbed.srt"
assert_nonempty "$WORK/clip-subbed.srt"

echo "[ffmpeg-min-smoke] verifying bundled ffprobe (BUG-1420)"
# BUG-1420: ffprobe was never built (--disable-ffprobe) even though Dart's
# resolveFfprobeExecutable() has always assumed it ships next to ffmpeg. Both of
# its consumers swallow the resulting ProcessException and degrade silently, so
# nothing ever went red. Exercise the two REAL argument shapes here, so a future
# --disable-ffprobe (or a JSON writer dropped by --disable-everything) fails the
# build instead of silently disabling two features for every user without a
# system ffmpeg on PATH.
if [ ! -x "$FFPROBE_MIN" ]; then
  echo "[ffmpeg-min-smoke] missing ffprobe binary: $FFPROBE_MIN" >&2
  echo "  build-ffmpeg-min.sh must pass --enable-ffprobe (BUG-1420)." >&2
  exit 1
fi

# Shape 1: container tag extraction -- buildFfprobeFormatTagsArgs()
# (fushi/lib/src/utils/misc/desktop_audio_clipper.dart). Feeds an audiobook file
# and reads format.tags.{title,artist,album}; a null result makes the importer
# fall back to the bare filename.
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a aac \
  -metadata title="Fushi Probe Title" \
  -metadata artist="Fushi Probe Artist" \
  -metadata album="Fushi Probe Album" \
  "$WORK/tagged.m4a"
"$FFPROBE_MIN" -v quiet -print_format json -show_format \
  "$WORK/tagged.m4a" >"$WORK/tags.json" 2>"$WORK/tags.err" || {
  echo "[ffmpeg-min-smoke] ffprobe -show_format failed:" >&2
  cat "$WORK/tags.err" >&2
  exit 1
}
assert_nonempty "$WORK/tags.json"
assert_log_contains "$WORK/tags.json" "Fushi Probe Title"
assert_log_contains "$WORK/tags.json" "Fushi Probe Artist"

# Shape 2: font attachment enumeration -- _enumerateFontAttachments()
# (fushi/lib/src/media/video/subtitle_embedded_fonts.dart). `-select_streams t`
# lists only attachment streams; the result drives ASS rendering with the video's
# own embedded fonts instead of the system fallback.
printf 'not-a-real-font-but-ffprobe-only-lists-the-stream' >"$WORK/fake.ttf"
run "$FIXTURE_FFMPEG" -hide_banner -loglevel error -y \
  -i "$MKV_FIXTURE" -c copy \
  -attach "$WORK/fake.ttf" \
  -metadata:s:t mimetype=application/x-truetype-font \
  "$WORK/attached.mkv"
"$FFPROBE_MIN" -v quiet -print_format json -show_streams -select_streams t \
  "$WORK/attached.mkv" >"$WORK/attachments.json" 2>"$WORK/attachments.err" || {
  echo "[ffmpeg-min-smoke] ffprobe -select_streams t failed:" >&2
  cat "$WORK/attachments.err" >&2
  exit 1
}
assert_nonempty "$WORK/attachments.json"
assert_log_contains "$WORK/attachments.json" "fake.ttf"

# BUG-1443: 自包含检查。上面所有断言都跑在**刚装完依赖的构建机**上，dylib 就在
# /opt/homebrew 下，所以「能跑」完全不代表用户机上能跑。macOS 的 ffmpeg 曾就这样
# 带着 4 条 Homebrew 动态依赖进了发版流水线，在装配步 `Abort trap: 6` (exit 134)。
# 这里直接看动态依赖表：凡是指向包管理器 / 家目录的共享库，一律当场失败——
# 构建机是唯一能便宜地发现这件事的地方，别再让它漏到发版。
assert_self_contained() {
  local binary="$1"
  local deps=""
  case "$(uname -s)" in
    # BUG-1668：按「依赖行必有缩进」取，别再用 `tail -n +2` 跳过表头。
    # `otool -L` 对**瘦**二进制只有一行表头（`/path/ffmpeg:`），对 **universal**
    # 则是每个架构一段：
    #     /path/ffmpeg (architecture x86_64):
    #     <TAB>/usr/lib/libSystem.B.dylib …
    #     /path/ffmpeg (architecture arm64):
    #     <TAB>/usr/lib/libSystem.B.dylib …
    # `tail -n +2` 只吃掉第一行，第二个架构的表头会被当成一条依赖；它是产物自身的
    # 绝对路径，在 CI 上正好长成 /Users/runner/…，直接命中下面的黑名单 → 产物明明
    # 自包含却报 FATAL（实测：改出 universal 后 CI 第一次就栽在这）。
    # 依赖行一律以制表符/空格开头、表头一律顶格，按缩进筛既修了假阳性，又顺带把
    # **两个架构**的依赖都纳入检查（比原来只看一段更严）。
    Darwin) deps="$(otool -L "$binary" | awk '/^[[:space:]]/ {print $1}')" ;;
    Linux) deps="$(objdump -p "$binary" | awk '/NEEDED|RPATH|RUNPATH/ {print $2}')
$(ldd "$binary" 2>/dev/null | awk '{print $3}')" ;;
    # Windows/MSYS：产物是 --extra-ldflags=-static 的单文件 PE，没有 Unix 式
    # 共享库路径可查；入库产物由 Dart 守卫字节扫描兜底。
    *) echo "[ffmpeg-min-smoke] self-contained check skipped on $(uname -s)"; return 0 ;;
  esac
  local foreign
  foreign="$(printf '%s\n' "$deps" | grep -E '^/(opt/homebrew|opt/local|usr/local|home|Users)/' || true)"
  if [ -n "$foreign" ]; then
    echo "[ffmpeg-min-smoke] FATAL(BUG-1443): $binary 依赖构建机专有的共享库：" >&2
    printf '%s\n' "$foreign" >&2
    echo "[ffmpeg-min-smoke] 这些路径在用户机上不存在，运行时直接 dyld/ld.so 崩溃。" >&2
    echo "[ffmpeg-min-smoke] 修法见 build-ffmpeg-min.sh 的 Darwin 分支（静态链第三方库）。" >&2
    exit 1
  fi
  echo "[ffmpeg-min-smoke] self-contained OK: $binary"
}
assert_self_contained "$FFMPEG_MIN"
assert_self_contained "$FFPROBE_MIN"

echo "[ffmpeg-min-smoke] PASS"
