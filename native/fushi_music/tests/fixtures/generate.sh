#!/usr/bin/env bash
# 重新生成 tests/fixtures/ 下的小音频样本（入库的是生成结果；改样本时重跑本脚本）。
#
# 用法: FFMPEG=<ffmpeg 可执行文件> bash native/fushi_music/tests/fixtures/generate.sh
#   用统一 FFmpeg（Windows 安装包里的 ffmpeg.exe 即是）：它带 flac / alac / libmp3lame /
#   wavpack / tta 编码器。样本全部 8 kHz 单声道正弦，几 KB 一个。
# DSF 样本不靠 FFmpeg（它没有 DSF muxer），用 python3 按规范写头部。
set -euo pipefail

FFMPEG="${FFMPEG:?set FFMPEG to an ffmpeg binary}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$DIR/library"
rm -rf "$lib"
mkdir -p "$lib/Album A" "$lib/Cue Album" "$lib/Embedded" "$lib/Formats"

sine() { # <seconds> <freq>
  printf 'sine=frequency=%s:sample_rate=8000:duration=%s' "$2" "$1"
}

ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

# 普通标签曲目（专辑艺人 + ReplayGain + 作曲）。
ff -f lavfi -i "$(sine 2 440)" -ac 1 -c:a flac -sample_fmt s16 \
  -metadata title="First Song" -metadata artist="Singer X" -metadata album="Album A" \
  -metadata album_artist="Singer X" -metadata track="1/2" -metadata disc="1/1" \
  -metadata date="2019-04-01" -metadata genre="J-Pop" -metadata composer="Writer Y" \
  -metadata REPLAYGAIN_TRACK_GAIN="-7.25 dB" -metadata REPLAYGAIN_TRACK_PEAK="0.98" \
  -metadata REPLAYGAIN_ALBUM_GAIN="-6.50 dB" -metadata REPLAYGAIN_ALBUM_PEAK="0.99" \
  "$lib/Album A/01 First Song.flac"
ff -f lavfi -i "$(sine 1 660)" -ac 1 -c:a libmp3lame -b:a 32k \
  -metadata title="Second Song" -metadata artist="Singer X" -metadata album="Album A" \
  -metadata album_artist="Singer X" -metadata track="2/2" \
  "$lib/Album A/02 Second Song.mp3"
# 目录封面（1x1 PNG）。
ff -f lavfi -i "color=c=red:s=1x1:d=1" -frames:v 1 "$lib/Album A/cover.png"

# 整轨 + CUE（Shift_JIS 编码、日文标题；第二首带 INDEX 00 pregap）。
ff -f lavfi -i "$(sine 3 330)" -ac 1 -c:a flac -sample_fmt s16 "$lib/Cue Album/full.flac"
printf '%s\r\n' \
  'REM GENRE "Anime"' \
  'REM DATE 2020' \
  'PERFORMER "Cue Artist"' \
  'TITLE "キュー盤"' \
  'FILE "full.wav" WAVE' \
  '  TRACK 01 AUDIO' \
  '    TITLE "夜に駆ける"' \
  '    INDEX 01 00:00:00' \
  '  TRACK 02 AUDIO' \
  '    TITLE "二曲目"' \
  '    INDEX 00 00:00:70' \
  '    INDEX 01 00:01:00' \
  '  TRACK 03 AUDIO' \
  '    TITLE "三曲目"' \
  '    PERFORMER "Guest"' \
  '    INDEX 01 00:02:00' \
  | iconv -f UTF-8 -t SHIFT_JIS > "$lib/Cue Album/full.cue"

# FLAC 内嵌 CUESHEET（Vorbis 注释文本）。
cuesheet=$'FILE "x.flac" WAVE\n  TRACK 01 AUDIO\n    TITLE "Inner One"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE "Inner Two"\n    INDEX 01 00:01:00\n'
ff -f lavfi -i "$(sine 2 550)" -ac 1 -c:a flac -sample_fmt s16 \
  -metadata album="Embedded Album" -metadata artist="Embed Artist" \
  -metadata CUESHEET="$cuesheet" \
  "$lib/Embedded/image.flac"

# 其它无损容器。
ff -f lavfi -i "$(sine 1 770)" -ac 1 -c:a alac -sample_fmt s16p \
  -metadata title="Alac Song" "$lib/Formats/alac.m4a"
ff -f lavfi -i "$(sine 1 880)" -ac 1 -c:a wavpack \
  -metadata title="WavPack Song" "$lib/Formats/wavpack.wv"
ff -f lavfi -i "$(sine 1 990)" -ac 1 -c:a tta "$lib/Formats/tta.tta"
# DSF（DSD64 立体声 0.05 秒，全 0x69 静音样式）：FFmpeg 没有 DSF muxer，按规范手写头部。
python3 - "$lib/Formats/dsd.dsf" <<'PYEOF'
import struct, sys
rate, ch, block = 2822400, 2, 4096
samples = rate // 20
blocks = -(-samples // (block * 8))
data = b'i' * (blocks * block * ch)
fmt = struct.pack('<4sQIIIIIIQII', b'fmt ', 52, 1, 0, 2, ch, rate, 1, samples, block, 0)
data_chunk = struct.pack('<4sQ', b'data', 12 + len(data)) + data
total = 28 + len(fmt) + len(data_chunk)
dsd = struct.pack('<4sQQQ', b'DSD ', 28, total, 0)
open(sys.argv[1], 'wb').write(dsd + fmt + data_chunk)
PYEOF
# 非音频与隐藏文件：扫描器必须忽略。
printf 'not audio' > "$lib/Formats/notes.txt"
printf 'x' > "$lib/Formats/.hidden.flac"

echo "fixtures regenerated under $lib"
