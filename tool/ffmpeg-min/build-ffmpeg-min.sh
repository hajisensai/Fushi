#!/usr/bin/env bash
# 构建 Hibiki 桌面用的「精简 ffmpeg」（~10MB 量级），只含 Hibiki 实际调用的组件：
#   - 内封字幕枚举/抽取（-i 探测 + -map 0:s:N 转 srt/ass/vtt）
#   - cue 动图（fps,scale,palettegen,paletteuse → gif）
#   - 句子音频片段（解码 → aac/adts）
#   - 视频帧/封面（-frames:v 1 → jpg/png）
#   - YouTube/远端制卡（http(s) googlevideo 流 + -reconnect 系列网络韧性开关）
#   - 片段导出 mp4（h264/libx264 + aac → .mp4，跨平台可打开，TODO-1257）
#
# 产物是**两个** exe：ffmpeg(.exe) + ffprobe(.exe)。BUG-1420 之前本脚本传
# `--disable-ffprobe`，但 Dart 侧 resolveFfprobeExecutable()（ffmpeg_backend.dart）
# 的注释与优先级链一直按「与 ffmpeg 并排捆绑」设计——配方与消费方各说各话，结果
# ffprobe 从来没被编出来过，桌面上恒走 PATH 回退。没装系统 ffmpeg 的机器上：
#   - 内封字幕字体（subtitle_embedded_fonts.dart）→ ProcessException → 恒空集，
#     ASS 字幕永远退回系统字体 fallback；
#   - 音频容器元数据（desktop_audio_clipper.dart 的 extractAudioMetadataViaFfprobe）
#     → 恒 null，有声书标题/作者永远退回文件名。
# 两处都是**静默降级**（各自就地兜住异常、不记日志），所以没人报过。ffprobe 走
# 同一份 configure 白名单，体积增量只是第二个静态 exe。
#
# 编码器：native gif/aac/mjpeg/png + libx264（H.264，TODO-1214/1257）。
# ⚠️ libx264 是 GPL，本 build 因此传 --enable-gpl → 产物许可从 LGPL 变为 GPL；
# ffmpeg(.exe) 作为独立可执行文件随 app 分发，源码即公开的 FFmpeg + x264，属分发合规范畴。
# 网络：--enable-network + http/https/tcp/tls 协议；TLS 后端走各平台原生库
# （Windows schannel / macOS SecureTransport 系统内置无外链；Linux 用 LGPL 的 gnutls），
# 无 openssl 许可麻烦。YouTube 制卡缺 network 会 AVERROR_OPTION_NOT_FOUND（-reconnect）。
#
# 用法：
#   FFMPEG_REF=n7.1.5 OUT=$PWD/out ./build-ffmpeg-min.sh
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
#
# ⚠️ 改下面任何一组组件清单后，**必须**重跑 .github/workflows/ffmpeg-min.yml 并把
# Windows artifact 重新 vendor 到 third_party/ffmpeg-min/windows/ffmpeg.exe。改脚本
# 不换二进制等于没改——用户跑的是入库的那个 exe（BUG-1058：movtext 漏了整整一版，
# 片段导出静默丢字幕）。守卫 hibiki/test/tools/ffmpeg_min_vendored_recipe_guard_test.dart
# 会静态比对本脚本与入库 exe 内嵌的 configure 串，漏 vendor 直接单测红。
set -euo pipefail

FFMPEG_REF="${FFMPEG_REF:-n7.1.5}"
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
# movtext：视频片段导出把「用户正在看的字幕」封成软字幕流（`-c:s mov_text`）。片段
# 输出恒 .mp4（BUG-917），而 ISO-BMFF 只认 3GPP Timed Text = movtext 编码器；缺它
# ffmpeg 直接 "Unknown encoder 'mov_text'"，字幕封装在桌面全挂（导出会自动降级成
# 无字幕片段，见 exportVideoClipViaFfmpeg 的降级重试，但字幕永远出不来）。
# 注意 movtext **解码器**早已在 DECODERS 里（读内嵌 mp4 字幕），编码器是另一个开关。
# libsvtav1 / libwebp_anim：制卡封面动图的 AVIF / WebP 编码器（默认格式已从 GIF 改为
# AVIF）。选 SVT-AV1 而非 libaom：本负载是几十帧的短片，延迟比压缩率重要，静态链接体积
# 也小一半。实测（1080p30 源 4 秒窗）：标准档 480px·8fps 下 AVIF 36 KB / GIF 471 KB /
# WebP 163 KB；原图档（源分辨率+源帧率）AVIF 3.5 秒 3.3 MB，反而比 GIF 的 12 秒 17.8 MB
# 又快又小，而 libwebp_anim 要 16.4 秒（它是逐帧帧内的静态图编码器，无运动补偿也不并行）。
# 二者均为 BSD 许可，本 build 已因 libx264 是 GPL，无新增许可约束。
# ⚠️ CI 构建环境需装 libsvtav1 / libwebp 开发包（MSYS2: mingw-w64-x86_64-{svt-av1,libwebp}）。
ENCODERS="gif,aac,mjpeg,png,libx264,libsvtav1,libwebp,libwebp_anim,ass,ssa,subrip,webvtt,movtext,pcm_s16le"
# pcm_s16le：能量探针（audio_energy_probe.dart，TODO-701）用 `-f null -`；null muxer 的
# 默认音频编码器是 pcm_s16le，缺它会报 "Default encoder for format null (codec pcm_s16le)
# is probably disabled ... Encoder not found"，探针在三平台全挂（TODO-1096）。
# mov：有声书片段导出（TODO-945 M4）把文本图(mjpeg)+句子音频(aac)合成成 .mov
# 短视频，需要一个能同时装视频+音频流的容器；adts/gif/mjpeg/image2 都只能单流。
# mov 是 LGPL、体积小，AAC 入 mov 自动经已编入的 aac_adtstoasc bsf（见 BSFS）。
# null: audio_energy_probe.dart uses -f null - to discard output and read astats metadata from stderr (TODO-701 subtitle auto-align)
# mp4：片段导出 mp4（TODO-1257）把 libx264 视频 + aac 音频合成 .mp4（比 .mov 更
# 通用、任意播放器/浏览器直接打开）；mp4 muxer 与 mov 同一 movenc，体积增量近零。
# avif / webp：动图封面的两个新容器（ffmpeg 按输出扩展名选 muxer）。avif muxer 自
# FFmpeg 6.1 进主线，本 build 钉的 n7.1.5 已有；它与 mov/mp4 同属 movenc，体积增量近零。
MUXERS="gif,adts,image2,mjpeg,mov,mp4,avif,webp,srt,ass,webvtt,null"
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
# http/https/tcp/tls/crypto：YouTube/远端制卡（TODO-1214）的 http(s) googlevideo
# 流输入。tls 协议需一个 TLS 后端（见下方按平台 --enable-schannel/securetransport/
# gnutls）。缺 network 会让 -reconnect 系列报 AVERROR_OPTION_NOT_FOUND。
PROTOCOLS="file,pipe,http,https,tcp,tls,crypto"

# TLS 后端按平台走系统原生库：Windows schannel（secur32，系统内置无额外 DLL）、
# macOS SecureTransport（系统内置）、Linux gnutls（LGPL，CI 装 libgnutls28-dev）。
# https(googlevideo) 输入的 tls 协议需要一个 TLS 后端，否则 configure 报错。
EXTRA_CONFIG="--enable-gnutls"
case "$(uname -s)" in
  # Windows：静态链接，把 libwinpthread/zlib/libgcc/x264 等折进 exe → 发布单文件，
  # 不依赖 MSYS2 mingw64 运行时 DLL（用户机没有 MSYS2）。schannel 是系统 secur32，无外链。
  MINGW*|MSYS*) EXTRA_CONFIG="--target-os=mingw32 --arch=x86_64 --extra-ldflags=-static --pkg-config-flags=--static --enable-schannel" ;;
  Darwin) EXTRA_CONFIG="--enable-securetransport" ;;
esac

./configure \
  --prefix="$OUT" \
  --disable-everything \
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
  --enable-network --disable-autodetect --disable-debug \
  --disable-ffplay --enable-ffprobe \
  --enable-ffmpeg \
  --enable-small --enable-zlib \
  --enable-gpl --enable-libx264 --enable-libsvtav1 --enable-libwebp \
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
