import 'dart:io';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_clip_exporter.dart'
    show extractFfmpegFailureReason;
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
// TODO-945 M4：把文本图（PNG）+ 音频片段（AAC）合成成一段短视频（mjpeg/.mov）。
//
// D-CODEC（实测捆绑 ffmpeg 只有 gif/mjpeg/png 视频编码器，无 libx264/mpeg4）：
// 用 `-c:v mjpeg`（Motion JPEG）+ `-c:a aac` 落 `.mov` 容器。GIF 无音轨故排除。
// 画面是静态文本图 `-loop 1`，音频驱动时长 `-shortest`。
//
// ⚠️ 容器（D-MUXER，BUG-460）：`.mov` 需要 mov muxer。精简 ffmpeg-min build
// （`--disable-everything`）原本只编入 adts/gif/mjpeg/image2 muxer，没有任何能同时
// 装视频+音频流的容器，写 `.mov` 会 exit -22（EINVAL）。已把 `mov` 加进
// `tool/ffmpeg-min/build-ffmpeg-min.sh` 的 MUXERS 白名单（AAC 入 mov 自动经已编入的
// `aac_adtstoasc` bsf）；本路径依赖重编后的 ffmpeg-min 产物随桌面发布更新。
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
/// - `-loop 1 -i img`：把单张 PNG 当无限循环视频流（静态画面）。
/// - `-i audio`：音频输入。两输入默认映射（无显式 -map，单流无歧义）。
/// - `-c:v mjpeg`：**捆绑包唯一带音轨容器可用的视频编码器**（D-CODEC，非 libx264）。
/// - `-pix_fmt yuvj420p`：mjpeg 的全范围 YUV420，最通用播放器兼容。
/// - `-c:a aac`：音频转 AAC（捆绑包唯一音频编码器，与桌面音频裁剪同源）。
/// - `-shortest`：以较短的输入（音频）定时长——图是无限 loop，必须靠音频收尾。
/// - `-r [fps]`：低帧率（静态画面无需高帧率，省体积/编码时间）。
/// - `-vf scale=...:force_original_aspect_ratio=decrease,pad=...`：把图缩放进
///   [width]×[height] 并居中黑边填充，保证输出维度恒定且为偶数（mjpeg 要求）。
///
/// 注意 mjpeg 不接受奇数维度；[width]/[height] 由调用方传偶数（720×1280 天然偶数）。
List<String> buildFfmpegImageAudioToVideoArgs({
  required String imagePath,
  required String audioPath,
  required String outputPath,
  int width = 720,
  int height = 1280,
  int fps = 12,
}) {
  // pad 居中黑边：scale 先按比例缩进框内，再 pad 到精确 WxH（偶数维度安全）。
  final String filter = 'scale=$width:$height:'
      'force_original_aspect_ratio=decrease,'
      'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:color=black';
  return <String>[
    '-hide_banner',
    '-y',
    '-loop',
    '1',
    '-i',
    imagePath,
    '-i',
    audioPath,
    '-c:v',
    'mjpeg',
    '-pix_fmt',
    'yuvj420p',
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

/// 把 [imagePath]（文本图）+ [audioPath]（片段音频）合成成 [outputPath]
/// （mjpeg/.mov 短视频）。返回成功/失败结果，绝不对调用方抛。
///
/// 镜像 [exportVideoClipViaFfmpeg]：有界超时、失败/超时清理半成品、ffmpeg 真因尾段
/// 写日志 + 回传 detail。[backend] 仅供测试注入，生产用 [resolveFfmpegBackend]。
Future<AudiobookClipSynthResult> synthAudiobookClipVideoViaFfmpeg({
  required String imagePath,
  required String audioPath,
  required String outputPath,
  int width = 720,
  int height = 1280,
  int fps = 12,
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

void _deleteClipSynthOutput(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
