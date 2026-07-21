import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
// BUG-835：extractFfmpegFailureReason 的正准实现在 ffmpeg_backend.dart（与
// FfmpegBackend 同层），直接从这里取，不再经 video_clip_exporter 转口。
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-945 M1：把「有声书查词选区 → 整句 cue 区间」的边界判定抽成纯函数，方便单测
/// 覆盖所有兜底分支（空选区 / 纯外字 / 跨章 / 跨音频文件），并让弹窗入口只负责收集
/// 输入 + 按结果路由（导出 / toast）。
///
/// 这里**不**做任何 ffmpeg / 视频合成（留给 M2-M5）；M1 仅把选区扩成单 cue / 单文件的
/// [AudioPlaybackRange] 并暴露所有无法导出的边界。

/// 选区 → 整句 cue 区间的分类结果（M1）。
enum AudiobookClipBoundaryKind {
  /// 选中文本为空（含纯外字图选区：JS 端选区文本会剔除 gaiji 图，纯外字 → 空文本）。
  emptySelection,

  /// 本书没有可用音频文件（无声书 / 控制器未就绪）。无音频不可能裁片段。
  noAudio,

  /// 选区命中文本，但 `_sentenceAudioRangeFor` 解析不出可裁区间。
  ///
  /// 实测覆盖两类：①跨章选区——cue 解析落空（`miningSentenceAudioRange` 返回 null）；
  /// ②跨音频文件选区——helper 天生只返回**单个** `audioFileIndex`，跨文件时只会落在
  /// 它命中的那一段或返回 null，永远不会拼出跨文件区间。两类在 M1 都走兜底提示，不导出。
  unsupportedRange,

  /// 可导出：拿到单 cue / 单文件的有效区间。
  exportable,
}

/// 选区 → 整句 cue 区间的判定结果（M1，纯数据）。
class AudiobookClipBoundaryResult {
  const AudiobookClipBoundaryResult({
    required this.kind,
    this.range,
  });

  final AudiobookClipBoundaryKind kind;

  /// 仅当 [kind] == [AudiobookClipBoundaryKind.exportable] 时非空，且
  /// `audioFileIndex` 已校验落在 [0, audioFileCount)。
  final AudioPlaybackRange? range;

  bool get isExportable => kind == AudiobookClipBoundaryKind.exportable;
}

/// 把「选中文本 + 整句音频区间 + 音频文件数」分类成 M1 的可导出 / 兜底结果。
///
/// 入参语义：
/// - [selectedText]：弹窗当前选中的词/片段文本（JS 端已剔除外字图；纯外字 → 空串）。
/// - [audioFileCount]：本会话可用音频文件数（控制器 `audioFiles?.length`，无音频传 0）。
/// - [sentenceRange]：`_sentenceAudioRangeFor(...)` 已算出的单 cue / 单文件区间（可空）。
///
/// 判定顺序固定（先空选区 → 再无音频 → 再无区间 → 否则可导出），保证每个分支互斥、
/// 可被单测逐一命中。**不**在这里访问任何可变 reader 状态，便于纯函数测试。
AudiobookClipBoundaryResult classifyAudiobookClipSelection({
  required String selectedText,
  required int audioFileCount,
  required AudioPlaybackRange? sentenceRange,
}) {
  if (selectedText.trim().isEmpty) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.emptySelection,
    );
  }
  if (audioFileCount <= 0) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.noAudio,
    );
  }
  final AudioPlaybackRange? range = sentenceRange;
  if (range == null ||
      range.audioFileIndex < 0 ||
      range.audioFileIndex >= audioFileCount ||
      range.endMs <= range.startMs) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.unsupportedRange,
    );
  }
  return AudiobookClipBoundaryResult(
    kind: AudiobookClipBoundaryKind.exportable,
    range: range,
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TODO-1115 多句连读 + 逐句高亮跟随：把「多句 cue 列表 + 全局裁剪窗口」分类成可导出
// 结果。沿用 [classifyAudiobookClipSelection] 的时长上限与单文件约束；多句按**全局
// 时长**判上限（首句 head-padded start .. 末句 tail-padded end）。
// ─────────────────────────────────────────────────────────────────────────

/// 多句片段里的一句：文本 + 该句在音频文件内的起止 ms（用于逐句高亮/帧计划）。
class AudiobookClipCueSpan {
  const AudiobookClipCueSpan({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;
}

/// 纯函数：把原始 cue span 转成导出用 [AudiobookClipCueSpan]，并应用 A/V 偏移
/// [delayMs]（TODO-1147 用户回访「高亮迟钝」第二根因·时基不一致）。
///
/// 时基契约：导出音频窗口（`clipExportGlobalRange`）已被 `_shiftRange` 平移
/// +delayMs——播放侧 `effectiveMs = pos - delayMs` 的镜像，即 cue 在音频里真实
/// 出现于 `startMs + delayMs`。帧计划（`clipFramePlan`）拿这个**已平移**的窗口当
/// 时间轴，cue 起止若不同步平移，逐句高亮整体偏移 delayMs（delay<0 时表现为固定
/// 迟钝、delay>0 时固定提前）。clamp 语义镜像 `_shiftRange`：起点不下穿 0，终点恒
/// > 起点。
List<AudiobookClipCueSpan> clipCueSpansWithDelay({
  required List<AudioCue> span,
  required int delayMs,
}) {
  return span.map((AudioCue c) {
    final int startMs = (c.startMs + delayMs).clamp(0, 1 << 30);
    final int endMs = (c.endMs + delayMs).clamp(startMs + 1, 1 << 30);
    return AudiobookClipCueSpan(
      text: c.text,
      startMs: startMs,
      endMs: endMs,
    );
  }).toList(growable: false);
}

/// Dynamic cards render cue text segment by segment. Only use that path when
/// the aligned cue text and the actual EPUB selection match after whitespace
/// normalization; otherwise the caller must render the exact selection.
bool audiobookClipCueTextMatchesSelection({
  required String selectedText,
  required List<AudiobookClipCueSpan> cueSpans,
}) {
  String normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');
  final String actual = normalize(selectedText);
  if (actual.isEmpty || cueSpans.isEmpty) return false;
  final String cueText = normalize(
    cueSpans.map((AudiobookClipCueSpan span) => span.text).join(),
  );
  return actual == cueText;
}

/// 多句片段导出的分类结果（纯数据）。
///
/// [kind] 复用 [AudiobookClipBoundaryKind]：emptySelection / noAudio /
/// unsupportedRange / exportable，语义同单句版。exportable 时 [cueSpans] 非空且
/// 已按 startMs 升序、同一 [audioFileIndex]，[globalStartMs]/[globalEndMs] 是整段
/// 完整音频的裁剪窗口（首句 head-padded start .. 末句 tail-padded end）。
/// TODO-1127：把从阅读器选区抽取到的 EPUB 插图按归一化文档偏移分配到各 cue 段（插图
/// 渲在其归属 cue 文本之后）。纯函数、可单测，与 [classifyAudiobookClipMultiCue] 解耦。
///
/// - [cueNormStarts]：每个 cue 段的 `normCharStart`（整书归一化字符偏移，跟
///   `SasayakiFragment.normCharStart` 同基准）；无法解码归一化偏移的 cue 传 `null`——
///   不作为归属锚点。长度必须与 cue 段数一致。
/// - [images]：抽取到的插图，每张带 [normOffset]（该图在 DOM 文档序里的归一化位置，由
///   JS `nativeSelectionImages` 用图片相邻文本节点算出）+ 载荷 [bytes]。
///
/// 归属规则：一张图挂到「归一化起点 `<=` 图片 normOffset 的最后一个 cue」之后——即这张
/// 图在 DOM 里出现在该句文本之后、下一句之前，正是「选区中间夹图」的相对顺序。没有任何
/// cue 起点 `<=` 图片偏移（图在所有 cue 之前，或所有 cue 都无法解码偏移）时兜底挂到第 0
/// 段最前，**绝不丢图**。多张图先按 normOffset 升序，保持文档序稳定。
///
/// 返回 `length == cueNormStarts.length` 的 `List<List<Uint8List>>`：第 i 项是第 i 个 cue
/// 段之后要渲的插图字节列表（顺序即文档序）。
List<List<Uint8List>> assignClipImagesToCues({
  required List<int?> cueNormStarts,
  required List<({int normOffset, Uint8List bytes})> images,
}) {
  final int cueCount = cueNormStarts.length;
  final List<List<Uint8List>> assigned = List<List<Uint8List>>.generate(
    cueCount,
    (_) => <Uint8List>[],
    growable: false,
  );
  if (cueCount == 0) return assigned;
  final List<({int normOffset, Uint8List bytes})> sorted =
      List<({int normOffset, Uint8List bytes})>.of(images)
        ..sort((({int normOffset, Uint8List bytes}) a,
                ({int normOffset, Uint8List bytes}) b) =>
            a.normOffset.compareTo(b.normOffset));
  for (final ({int normOffset, Uint8List bytes}) image in sorted) {
    int target = 0; // 兜底：图在所有 cue 之前 / 无可用锚点 → 挂最前一段，绝不丢。
    for (int i = 0; i < cueCount; i++) {
      final int? start = cueNormStarts[i];
      if (start != null && start <= image.normOffset) target = i;
    }
    assigned[target].add(image.bytes);
  }
  return assigned;
}

class AudiobookClipMultiCueResult {
  const AudiobookClipMultiCueResult({
    required this.kind,
    this.audioFileIndex = -1,
    this.globalStartMs = 0,
    this.globalEndMs = 0,
    this.cueSpans = const <AudiobookClipCueSpan>[],
  });

  final AudiobookClipBoundaryKind kind;
  final int audioFileIndex;
  final int globalStartMs;
  final int globalEndMs;
  final List<AudiobookClipCueSpan> cueSpans;

  bool get isExportable => kind == AudiobookClipBoundaryKind.exportable;
}

/// 把「选中文本 + 多句 cue 列表 + 全局裁剪窗口 + 音频文件数」分类成多句可导出结果。
///
/// [globalRange] 是 [miningSentenceAudioRange]（含 head/tail padding + A/V 偏移）算出的
/// 整段完整音频窗口——**单一真相源**，多句路径不再自己拼窗口，避免与音频裁剪窗口漂移。
/// [cueStartEndMs] 是每句 `(text, startMs, endMs)`（原始 cue，未加 padding），供逐句高亮。
///
/// 判定顺序与单句版一致（空选区 → 无音频 → 无区间 → 否则可导出）。多句按**全局时长**
/// 判上限 [maxDurationMs]；超限走 unsupportedRange（回退单句静态）。
AudiobookClipMultiCueResult classifyAudiobookClipMultiCue({
  required String selectedText,
  required int audioFileCount,
  required AudioPlaybackRange? globalRange,
  required List<AudiobookClipCueSpan> cueSpans,
  int maxDurationMs = 120 * 1000,
}) {
  if (selectedText.trim().isEmpty) {
    return const AudiobookClipMultiCueResult(
      kind: AudiobookClipBoundaryKind.emptySelection,
    );
  }
  if (audioFileCount <= 0) {
    return const AudiobookClipMultiCueResult(
      kind: AudiobookClipBoundaryKind.noAudio,
    );
  }
  if (globalRange == null ||
      cueSpans.isEmpty ||
      globalRange.audioFileIndex < 0 ||
      globalRange.audioFileIndex >= audioFileCount ||
      globalRange.endMs <= globalRange.startMs ||
      globalRange.endMs - globalRange.startMs > maxDurationMs) {
    return const AudiobookClipMultiCueResult(
      kind: AudiobookClipBoundaryKind.unsupportedRange,
    );
  }
  return AudiobookClipMultiCueResult(
    kind: AudiobookClipBoundaryKind.exportable,
    audioFileIndex: globalRange.audioFileIndex,
    globalStartMs: globalRange.startMs,
    globalEndMs: globalRange.endMs,
    cueSpans: List<AudiobookClipCueSpan>.unmodifiable(cueSpans),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TODO-945 M4：把文本图 + 音频片段（AAC）合成成一段短视频。
//
// 编码器按后端能力分流（[_clipVideoCodecArgs]，BUG-809）：
// - 桌面 ffmpeg-min 自 `e039cf760`（2026-07-07，TODO-1257）已编入 `libx264`（H.264）+
//   `mp4` muxer → 桌面用 `-c:v libx264` + `.mp4`：**带帧间压缩**，逐句高亮跟随里大量
//   重复帧压到近零字节，30 秒片段从旧 mjpeg 的 ~200MB 降到几 MB，且 .mp4 任意播放器/
//   浏览器/社交平台可直接打开。
// - 移动端自编 ffmpeg-kit **min** 变体无外部 GPL 库（无 libx264），仍用 `-c:v mjpeg`
//   （Motion JPEG，帧内 JPEG）+ `.mov` 容器。GIF 无音轨故排除。
// 两条路径都 `-c:a aac`；单图路径 `-loop 1` + `-shortest`，序列帧路径 `-framerate`。
//
// ⚠️ 容器（D-MUXER，BUG-460）：`.mov`/`.mp4` 都需要能同时装视频+音频流的 mov/mp4
// muxer；精简 ffmpeg-min build（`--disable-everything`）原本只编入 adts/gif/mjpeg/
// image2 单流 muxer，写这类容器会 exit -22（EINVAL）。`mov`+`mp4` 均已加进
// `tool/ffmpeg-min/build-ffmpeg-min.sh` 的 MUXERS 白名单（AAC 入 mov/mp4 自动经已编入
// 的 `aac_adtstoasc` bsf）；本路径依赖重编后的 ffmpeg-min 产物随桌面发布更新。
// ─────────────────────────────────────────────────────────────────────────

/// 片段视频合成的失败原因。
enum AudiobookClipSynthFailure {
  /// 输入图片或音频缺失。
  inputMissing,

  /// ffmpeg 不可用（桌面无 CLI / 移动无 kit）。
  ffmpegUnavailable,

  /// ffmpeg 跑了但失败（非零退出 / 超时）。
  ffmpegFailed,

  /// ffmpeg 成功但没产出文件。
  outputMissing,
}

/// 片段视频合成结果（成功带输出路径，失败带原因 + ffmpeg 真因尾段）。
class AudiobookClipSynthResult {
  const AudiobookClipSynthResult._({
    required this.outputPath,
    required this.failure,
    this.detail,
  });

  const AudiobookClipSynthResult.success(String outputPath)
      : this._(outputPath: outputPath, failure: null);

  const AudiobookClipSynthResult.failure(
    AudiobookClipSynthFailure failure, {
    String? detail,
  }) : this._(outputPath: null, failure: failure, detail: detail);

  final String? outputPath;
  final AudiobookClipSynthFailure? failure;
  final String? detail;

  bool get isSuccess => outputPath != null && failure == null;
}

/// 纯函数：构建「静态图 + 音频 → mjpeg/.mov 短视频」的 ffmpeg 参数表。可单测。
///
/// 关键参数与理由：
/// - `-f image2 -loop 1 -i img`：把单张 **JPEG** 图当无限循环视频流（静态画面）。显式
///   `-f image2`（image2 demuxer，桌面 ffmpeg-min 与移动端自编 ffmpeg-kit min AAR
///   两端白名单都含），避免依赖后缀嗅探。
/// - **为何 JPEG 而非 PNG（BUG-543，根因）**：移动端自编 ffmpeg-kit **min** 变体的
///   libavcodec **没有 png decoder**（AAR 实证：`.rodata` 有 `MJPEG decoder` / `gif
///   decoder` / `BMP decoder`，独缺 `PNG decoder`；运行时报 `Decoder (codec png) not
///   found` → 帧解不出 → `unspecified size` → 合成 exit 1）。但它**有 mjpeg decoder**。
///   桌面 ffmpeg-min 同样含 mjpeg decoder（build-ffmpeg-min.sh DECODERS 列 `mjpeg`），
///   故把静止文本帧统一喂 JPEG，两端都走已存在的 mjpeg 解码，不再触碰缺失的 png。
/// - `-i audio`：音频输入。两输入默认映射（无显式 -map，单流无歧义）。
/// - `-c:v mjpeg`：**捆绑包唯一带音轨容器可用的视频编码器**（D-CODEC，非 libx264）。
/// - `-q:v 2 -pix_fmt [pixFmt]`（TODO-1147）：mjpeg 近最佳 qscale 消除默认 qscale 二次
///   有损；[pixFmt] 桌面传 `yuvj444p`（去色度下采样，保彩色文字边缘），移动端保守传
///   `yuvj420p`（自编 ffmpeg-kit min 的 mjpeg encoder 收 444 需真机验合成不 exit）。
/// - `-c:a aac`：音频转 AAC（捆绑包唯一音频编码器，与桌面音频裁剪同源）。
/// - `-shortest`：以较短的输入（音频）定时长——图是无限 loop，必须靠音频收尾。
/// - `-r [fps]`：低帧率（静态画面无需高帧率，省体积/编码时间）。
/// - `-vf scale=...:force_original_aspect_ratio=decrease,pad=...`：把图缩放进
///   [width]×[height] 并居中黑边填充，保证输出维度恒定且为偶数（mjpeg 要求）。
///
/// 注意 mjpeg 不接受奇数维度；[width]/[height] 由调用方传偶数（720×1280 天然偶数）。
/// [imagePath] 必须指向 JPEG 内容（调用方经 [encodeClipTextFrameAsJpg] 落盘 `.jpg`）。
List<String> buildFfmpegImageAudioToVideoArgs({
  required String imagePath,
  required String audioPath,
  required String outputPath,
  int width = 1080,
  int height = 1920,
  int fps = 12,
  String pixFmt = 'yuvj444p',
  bool h264 = false,
}) {
  // pad 居中黑边：scale 先按比例缩进框内，再 pad 到精确 WxH（偶数维度安全）。
  final String filter = 'scale=$width:$height:'
      'force_original_aspect_ratio=decrease,'
      'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black';
  return <String>[
    '-hide_banner',
    '-y',
    '-f',
    'image2',
    '-loop',
    '1',
    '-i',
    imagePath,
    '-i',
    audioPath,
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    ..._clipVideoCodecArgs(h264: h264, pixFmt: pixFmt),
    '-r',
    '$fps',
    '-vf',
    filter,
    '-c:a',
    'aac',
    '-shortest',
    outputPath,
  ];
}

/// BUG-809：按后端能力选视频编码器。桌面 ffmpeg-min 自 `e039cf760`（2026-07-07）
/// 已编入 `libx264`（H.264）+ `mp4` muxer，故桌面导出用 [h264]=true 走 H.264：带
/// 帧间压缩（P/B 帧），逐句高亮跟随里大量重复帧压到近零字节，30 秒片段从 mjpeg 的
/// ~200MB 降到几 MB，容器换 `.mp4`（任意播放器/浏览器/社交平台可直接打开）。
/// 移动端自编 ffmpeg-kit **min** 变体无外部 GPL 库（无 libx264），[h264] 保持 false
/// 走原 `mjpeg`（帧内 JPEG，体积大但两端都能编）。
///
/// - H.264：`-preset veryfast`（桌面导出体感快，文字/纯色底压缩率仍极高）+ `-crf 20`
///   （高质量近视觉无损）+ `-pix_fmt yuv420p`（最大兼容，非 mjpeg 的 yuvj*）+
///   `-movflags +faststart`（moov 前置，边下边播/网页直开）。
/// - mjpeg：`-q:v 2`（近最佳 qscale 消二次有损）+ [pixFmt]（桌面 yuvj444p / 移动
///   yuvj420p，TODO-1147）。
List<String> _clipVideoCodecArgs({
  required bool h264,
  required String pixFmt,
}) {
  if (h264) {
    return const <String>[
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '20',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
    ];
  }
  return <String>[
    '-c:v',
    'mjpeg',
    '-q:v',
    '2',
    '-pix_fmt',
    pixFmt,
  ];
}

/// 纯函数：把 Flutter 离屏栅格化出的 **PNG** 字节（[renderAudiobookClipTextToPng]
/// / [renderAudiobookClipFrames] 唯一支持的输出格式）重编码成 **JPEG** 字节，供
/// [buildFfmpegImageAudioToVideoArgs]（单图）或 [buildFfmpegImageSeqAudioToVideoArgs]
/// （序列帧）的 image2 输入使用。
///
/// 根因（BUG-543）：移动端 ffmpeg-kit min 变体无 png decoder 但有 mjpeg decoder；
/// Flutter `Image.toByteData` 又只支持 png/rawRgba（不支持直出 jpeg），且移动/桌面
/// min 均无 rawvideo demuxer/decoder。故在 Dart 层用 `package:image` 把 png 解码后
/// 以 jpeg 重编码，得到两端 ffmpeg 都能解的静止帧。单图版与逐帧动态版（TODO-1115）
/// 共用此重编码，两条路径都只喂 JPEG，绝不触碰缺失的 png decoder。
///
/// [pngBytes] 解码失败（损坏/空）返回 null，调用方据此回退（记日志 + toast）。
/// [quality] 为 JPEG 质量（1-100），静态文本卡片用高质量避免文字边缘锯齿。
Uint8List? encodeClipTextFrameAsJpg(
  Uint8List pngBytes, {
  int quality = 98,
}) {
  final img.Image? decoded = img.decodeImage(pngBytes);
  if (decoded == null) return null;
  return img.encodeJpg(decoded, quality: quality);
}

/// [encodeClipTextFrameAsJpg] 的后台 isolate 版本（TODO-1167 / BUG-552，安卓导出片段
/// 视频 ANR/OOM 根因修复）。
///
/// 根因：导出长片段时 `_synthDynamicClipVideo` 与静态回退在 **UI isolate** 同步逐帧调
/// [encodeClipTextFrameAsJpg]（2MP=1080×1920 PNG 解码 + JPEG 编码，每帧数十 ms），N 帧
/// 串起来同步无 await 冻死主线程 → 安卓 ANR 杀进程。这里把纯 Dart 的解码/编码整体卸到
/// 后台 isolate（[Isolate.run]）：传 [Uint8List]（PNG bytes）进、[Uint8List]（JPEG bytes）
/// 出，`package:image` 对象只在后台 isolate 内生灭（不能跨 isolate 传句柄），UI 线程不再
/// 被 2MP 解码/编码阻塞。解码失败返回 null，语义与同步版完全一致，调用方据此回退。
Future<Uint8List?> encodeClipTextFrameAsJpgAsync(
  Uint8List pngBytes, {
  int quality = 98,
}) {
  return Isolate.run<Uint8List?>(
    () => encodeClipTextFrameAsJpg(pngBytes, quality: quality),
  );
}

/// 纯函数：构建「逐帧 JPEG 序列 + 音频 → mjpeg/.mov 短视频」的 ffmpeg 参数表（可单测）。
///
/// TODO-1115 动态高亮跟随：捆绑 ffmpeg-min **无 overlay/drawtext/concat/subtitles
/// filter**，所以逐句高亮只能靠 Flutter 侧逐帧渲 PNG，ffmpeg 只做「读序列帧 + 拼音频」。
/// 用 image2 demuxer 读 `frame_%04d.jpg` 序列帧（[framePattern]，如 `frame_%04d.jpg`），
/// [framesDir] 是序列帧所在目录。
///
/// **为何 JPEG 而非 PNG（BUG-543，根因）**：移动端自编 ffmpeg-kit **min** 变体的
/// libavcodec **没有 png decoder**（只有 mjpeg/gif/bmp decoder），桌面 ffmpeg-min 同样
/// 含 mjpeg decoder 而无 png decoder。Flutter 离屏只能直出 png，故渲染层每帧 png 先经
/// [encodeClipTextFrameAsJpg] 重编码为 jpeg 落盘（`frame_%04d.jpg`），两端 image2 序列帧
/// 都走已存在的 mjpeg 解码，绝不触碰缺失的 png decoder（否则移动端合成 exit 1）。
///
/// 关键参数与理由（沿用单图版 D-CODEC 天花板：仅 mjpeg 视频 + aac 音频）：
/// - `-framerate <fps> -i <framesDir>/<pattern>`：image2 demuxer 按 [fps] 读序列帧。
///   **不用** `-loop 1`（那是单张静态图）；序列帧本身携带时间轴。
/// - `-i audio`：完整音频输入。
/// - `-c:v mjpeg` / `-q:v 2` / `-pix_fmt [pixFmt]`（TODO-1147）：捆绑包唯一带音轨容器
///   可用的视频编码器（非 libx264）+ 近最佳 qscale + 桌面 444 / 移动 420 见单图版。
/// - `-c:a aac`：捆绑包唯一音频编码器。
/// - `-shortest`：以较短输入收尾（帧数×1/fps 与音频时长对齐时二者相近，防尾端错位）。
/// - `-vf scale=...:pad=...`：缩放+黑边填充到精确偶数维度（mjpeg 要求偶数维度）。
///
/// **天花板守卫**：绝不含 libx264/h264/concat/overlay/drawtext，且序列帧输入必为 JPEG
/// （非需 png decoder 的 .png）——由 audiobook_clip_synth_test 断言。序列帧 JPEG 已由渲染层
/// 按每帧 highlightCueIndex 逐帧生成后经 [encodeClipTextFrameAsJpg] 重编码。
List<String> buildFfmpegImageSeqAudioToVideoArgs({
  required String framesDir,
  required String audioPath,
  required String outputPath,
  String framePattern = 'frame_%04d.jpg',
  int width = 1080,
  int height = 1920,
  int fps = 12,
  String pixFmt = 'yuvj444p',
  bool h264 = false,
}) {
  final String filter = 'scale=$width:$height:'
      'force_original_aspect_ratio=decrease,'
      'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black';
  // 用正斜杠拼输入模式：ffmpeg 在所有平台都接受 `/`；Windows 反斜杠会被 image2
  // demuxer 的 `%d` 解析规则误伤。
  final String inputPattern =
      framesDir.endsWith('/') || framesDir.endsWith('\\')
          ? '$framesDir$framePattern'
          : '$framesDir/$framePattern';
  return <String>[
    '-hide_banner',
    '-y',
    '-framerate',
    '$fps',
    '-i',
    inputPattern,
    '-i',
    audioPath,
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    // BUG-809：桌面 h264（带帧间压缩，逐句高亮的大量重复帧压到近零）/ 移动 mjpeg。
    ..._clipVideoCodecArgs(h264: h264, pixFmt: pixFmt),
    '-vf',
    filter,
    '-c:a',
    'aac',
    '-shortest',
    outputPath,
  ];
}

/// 把 [imagePath]（文本图）+ [audioPath]（片段音频）合成成 [outputPath]
/// （mjpeg/.mov 短视频）。返回成功/失败结果，绝不对调用方抛。
///
/// 镜像 [exportVideoClipViaFfmpeg]：有界超时、失败/超时清理半成品、ffmpeg 真因尾段
/// 写日志 + 回传 detail。[backend] 仅供测试注入，生产用 [resolveFfmpegBackend]。
Future<AudiobookClipSynthResult> synthAudiobookClipVideoViaFfmpeg({
  required String imagePath,
  required String audioPath,
  required String outputPath,
  int width = 1080,
  int height = 1920,
  int fps = 12,
  String pixFmt = 'yuvj444p',
  bool h264 = false,
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final File output = File(outputPath);
  if (!File(imagePath).existsSync() || !File(audioPath).existsSync()) {
    _deleteClipSynthOutput(output);
    return const AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.inputMissing,
    );
  }

  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result =
        await (backend ?? resolveFfmpegBackend()).run(
      buildFfmpegImageAudioToVideoArgs(
        imagePath: imagePath,
        audioPath: audioPath,
        outputPath: outputPath,
        width: width,
        height: height,
        fps: fps,
        pixFmt: pixFmt,
        h264: h264,
      ),
      timeout,
    );
    if (result.isSuccess && output.existsSync() && output.lengthSync() > 0) {
      return AudiobookClipSynthResult.success(outputPath);
    }
    _deleteClipSynthOutput(output);
    if (result.isSuccess) {
      return const AudiobookClipSynthResult.failure(
        AudiobookClipSynthFailure.outputMissing,
      );
    }
    ErrorLogService.instance.log('AudiobookClipSynth', result.failureSummary);
    final String reason = extractFfmpegFailureReason(result.output);
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegFailed,
      detail: reason.isEmpty ? null : reason,
    );
  } on ProcessException catch (e, stack) {
    _deleteClipSynthOutput(output);
    ErrorLogService.instance.log(
      'AudiobookClipSynth',
      describeFfmpegProcessException(e),
      stack,
    );
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegUnavailable,
      detail: e.message,
    );
  } catch (e, stack) {
    _deleteClipSynthOutput(output);
    ErrorLogService.instance.log('AudiobookClipSynth', e, stack);
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegFailed,
      detail: e.toString(),
    );
  }
}

/// TODO-1115：把 [framesDir] 里的 JPEG 序列帧（`frame_%04d.jpg`，BUG-543）+ [audioPath] 完整音频
/// 合成成 [outputPath]（mjpeg/.mov 逐句高亮跟随短视频）。镜像
/// [synthAudiobookClipVideoViaFfmpeg]：有界超时、失败/超时清理半成品、ffmpeg 真因写日志，
/// 绝不对调用方抛。序列帧由渲染层按帧计划落盘（[buildFfmpegImageSeqAudioToVideoArgs]）。
Future<AudiobookClipSynthResult> synthAudiobookClipFrameSeqVideoViaFfmpeg({
  required String framesDir,
  required String audioPath,
  required String outputPath,
  String framePattern = 'frame_%04d.jpg',
  int width = 1080,
  int height = 1920,
  int fps = 12,
  String pixFmt = 'yuvj444p',
  bool h264 = false,
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final File output = File(outputPath);
  if (!Directory(framesDir).existsSync() || !File(audioPath).existsSync()) {
    _deleteClipSynthOutput(output);
    return const AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.inputMissing,
    );
  }

  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result =
        await (backend ?? resolveFfmpegBackend()).run(
      buildFfmpegImageSeqAudioToVideoArgs(
        framesDir: framesDir,
        audioPath: audioPath,
        outputPath: outputPath,
        framePattern: framePattern,
        width: width,
        height: height,
        fps: fps,
        pixFmt: pixFmt,
        h264: h264,
      ),
      timeout,
    );
    if (result.isSuccess && output.existsSync() && output.lengthSync() > 0) {
      return AudiobookClipSynthResult.success(outputPath);
    }
    _deleteClipSynthOutput(output);
    if (result.isSuccess) {
      return const AudiobookClipSynthResult.failure(
        AudiobookClipSynthFailure.outputMissing,
      );
    }
    ErrorLogService.instance
        .log('AudiobookClipSeqSynth', result.failureSummary);
    final String reason = extractFfmpegFailureReason(result.output);
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegFailed,
      detail: reason.isEmpty ? null : reason,
    );
  } on ProcessException catch (e, stack) {
    _deleteClipSynthOutput(output);
    ErrorLogService.instance.log(
      'AudiobookClipSeqSynth',
      describeFfmpegProcessException(e),
      stack,
    );
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegUnavailable,
      detail: e.message,
    );
  } catch (e, stack) {
    _deleteClipSynthOutput(output);
    ErrorLogService.instance.log('AudiobookClipSeqSynth', e, stack);
    return AudiobookClipSynthResult.failure(
      AudiobookClipSynthFailure.ffmpegFailed,
      detail: e.toString(),
    );
  }
}

void _deleteClipSynthOutput(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
