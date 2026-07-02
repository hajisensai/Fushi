#!/usr/bin/env bash
# 构建 Hibiki 桌面用的「精简 ffmpeg」（~10MB 量级），只含 Hibiki 实际调用的组件：
#   - 内封字幕枚举/抽取（-i 探测 + -map 0:s:N 转 srt/ass/vtt）
#   - cue 动图（fps,scale,palettegen,paletteuse → gif）
#   - 句子音频片段（解码 → aac/adts）
#   - 视频帧/封面（-frames:v 1 → jpg/png）
#
# 只解码 + 用 native gif/aac/mjpeg 编码 → 不需要任何 GPL 外部编码器（x264 等），
# 故 LGPL（不传 --enable-gpl），体积与许可都更干净。
#
# 用法：
#   FFMPEG_REF=n7.1 OUT=$PWD/out ./build-ffmpeg-min.sh
# 产物：$OUT/bin/ffmpeg(.exe)。把它放到 app 程序旁即被
# resolveFfmpegExecutable()（lib/src/media/video/ffmpeg_backend.dart）优先选用。
#
# 平台：
#   - Linux / macOS：原生 toolchain（gcc/clang + make + nasm/yasm + pkg-config）。
#   - Windows：在 MSYS2 mingw64 shell 里跑本脚本（需 base-devel + mingw-w64-x86_64-{gcc,nasm,pkg-config}）。
#
# ⚠️ 本脚本是 v0 脚手架：configure 精简白名单需在真实构建上「编译 + 用真实视频跑通
# 四类命令」迭代收敛（漏一个 decoder/parser/bsf/filter → 某些视频运行时失败）。
# 调优清单见 docs/specs/2026-06-07-ffmpeg-min-build-pipeline.md。
set -euo pipefail

FFMPEG_REF="${FFMPEG_REF:-n7.1}"
OUT="${OUT:-$PWD/ffmpeg-min-out}"
SRC="${SRC:-$PWD/ffmpeg-src}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

if [ ! -d "$SRC/.git" ]; then
  echo "[ffmpeg-min] clone FFmpeg @ $FFMPEG_REF"
  git clone --depth 1 --branch "$FFMPEG_REF" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi
cd "$SRC"

# 组件白名单（覆盖 Hibiki 四类命令；按需在调优清单里增删）。
# image2/image2pipe：有声书片段导出（TODO-945 M4 / TODO-1096）用 `-loop 1 -i clip.png`
# 把单张 PNG 当循环视频流喂进合成命令。`-loop` 是 image2 demuxer 的输入选项，读命名 PNG
# 文件走 image2；若改走管道则用 image2pipe——两者都加，零体积成本、LGPL。漏 image2 会让
# ffmpeg 找不到 PNG 的 demuxer → AVERROR_INVALIDDATA（exit -1094995529，"Invalid data found
# when processing input"），片段导出全挂（AudiobookClipSynthFailure.ffmpegFailed）。
DEMUXERS="matroska,mov,mpegts,mpegps,mpegvideo,avi,flv,rm,asf,srt,ass,webvtt,aac,ac3,eac3,mp3,flac,wav,ogg,m4v,image2,image2pipe"
DECODERS="h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,mpeg1video,flv,rv10,rv20,rv30,rv40,theora,wmv1,wmv2,wmv3,vc1,msmpeg4v1,msmpeg4v2,msmpeg4v3,mjpeg,png,webp,opus,aac,ac3,eac3,vorbis,flac,mp3,mp2,alac,dca,truehd,mlp,cook,sipr,ra_144,ra_288,wmav1,wmav2,wmapro,wmalossless,wmavoice,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw,ass,ssa,subrip,webvtt,movtext,text"
ENCODERS="gif,aac,mjpeg,png,ass,ssa,subrip,webvtt,pcm_s16le"
# pcm_s16le：能量探针（audio_energy_probe.dart，TODO-701）用 `-f null -`；null muxer 的
# 默认音频编码器是 pcm_s16le，缺它会报 "Default encoder for format null (codec pcm_s16le)
# is probably disabled ... Encoder not found"，探针在三平台全挂（TODO-1096）。
# mov：有声书片段导出（TODO-945 M4）把文本图(mjpeg)+句子音频(aac)合成成 .mov
# 短视频，需要一个能同时装视频+音频流的容器；adts/gif/mjpeg/image2 都只能单流。
# mov 是 LGPL、体积小，AAC 入 mov 自动经已编入的 aac_adtstoasc bsf（见 BSFS）。
# null: audio_energy_probe.dart uses -f null - to discard output and read astats metadata from stderr (TODO-701 subtitle auto-align)
MUXERS="gif,adts,image2,mjpeg,mov,srt,ass,webvtt,null"
# pad：有声书片段导出（buildFfmpegImageAudioToVideoArgs）用
#   `scale=W:H:force_original_aspect_ratio=decrease,pad=W:H:(ow-iw)/2:(oh-ih)/2:color=black`
#   把文本图缩进框内再黑边填充到精确 WxH；漏 pad → "No option name near '...'" +
#   "Error parsing filterchain" 解析失败，片段导出全挂。
# asetnsamples/astats/ametadata：音频能量探针（buildFfmpegPcmEnvelopeArgs，
#   audio_energy_probe.dart，TODO-701 字幕自动对轴）用
#   `aresample=R,asetnsamples=n=N:p=0,astats=metadata=1:reset=1,ametadata=print:key=...`
#   逐帧算 RMS 能量；三者缺一即滤镜链解析失败 → 空包络。aresample 已在。
FILTERS="scale,fps,split,palettegen,paletteuse,format,aformat,aresample,anull,null,copy,setpts,asetpts,pad,asetnsamples,astats,ametadata"
PARSERS="h264,hevc,av1,vp9,vp8,mpeg4video,mpegvideo,vc1,aac,aac_latm,ac3,dca,mlp,mpegaudio,vorbis,opus,flac,mjpeg,png,webp"
BSFS="aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb"
PROTOCOLS="file,pipe"

EXTRA_CONFIG=""
case "$(uname -s)" in
  # Windows：静态链接，把 libwinpthread/zlib/libgcc 等折进 exe → 发布单文件，
  # 不依赖 MSYS2 mingw64 运行时 DLL（用户机没有 MSYS2）。
  MINGW*|MSYS*) EXTRA_CONFIG="--target-os=mingw32 --arch=x86_64 --extra-ldflags=-static --pkg-config-flags=--static" ;;
esac

./configure \
  --prefix="$OUT" \
  --disable-everything \
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --disable-network --disable-autodetect --disable-debug \
  --disable-ffplay --disable-ffprobe \
  --enable-ffmpeg \
  --enable-small --enable-zlib \
  --enable-avcodec --enable-avformat --enable-avfilter \
  --enable-swscale --enable-swresample \
  --enable-demuxer="$DEMUXERS" \
  --enable-decoder="$DECODERS" \
  --enable-encoder="$ENCODERS" \
  --enable-muxer="$MUXERS" \
  --enable-filter="$FILTERS" \
  --enable-parser="$PARSERS" \
  --enable-bsf="$BSFS" \
  --enable-protocol="$PROTOCOLS" \
  $EXTRA_CONFIG

make -j"$JOBS"
make install

echo "[ffmpeg-min] done →"
ls -la "$OUT/bin/" 2>/dev/null || true
