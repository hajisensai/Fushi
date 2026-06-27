import 'dart:io';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

enum VideoClipExportFailure {
  invalidRange,
  inputMissing,
  ffmpegUnavailable,
  ffmpegFailed,
  outputMissing,
}

class VideoClipExportResult {
  const VideoClipExportResult._({
    required this.outputPath,
    required this.failure,
    this.detail,
  });

  const VideoClipExportResult.success(String outputPath)
      : this._(outputPath: outputPath, failure: null);

  const VideoClipExportResult.failure(
    VideoClipExportFailure failure, {
    String? detail,
  }) : this._(outputPath: null, failure: failure, detail: detail);

  final String? outputPath;
  final VideoClipExportFailure? failure;
  final String? detail;

  bool get isSuccess => outputPath != null && failure == null;
}

List<String> buildFfmpegVideoClipExportArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
}) {
  final double startSeconds = startMs / 1000.0;
  final double durationSeconds = (endMs - startMs) / 1000.0;
  final int? explicitAudio = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  return <String>[
    '-hide_banner',
    '-y',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    if (explicitAudio != null) ...<String>[
      '-map',
      '0:v:0',
      '-map',
      // 尾随 '?'：当 0:a:N 在真实 ffmpeg 流里越界（mpv 轨序号与 ffmpeg 0:a:N 不一致，
      // 挂外挂音频/枚举顺序不同时发生），ffmpeg 降级回退默认轨而非
      // 'Stream map matches no streams' 硬失败（BUG-345）。
      '0:a:$explicitAudio?',
    ],
    '-sn',
    '-dn',
    '-c',
    'copy',
    '-avoid_negative_ts',
    'make_zero',
    outputPath,
  ];
}

/// 纯函数：把请求的 [audioStreamIndex] 归一成「实际拼进 `-map 0:a:N` 的下标」，
/// 否则返回 null（不加 `-map`，用 ffmpeg 默认音频选择）。两条 ffmpeg 裁剪路径
/// （视频片段导出 / 桌面音频裁剪）共用这套边界判定（BUG-345）。
///
/// 归一规则：
/// - index 为 null 或负数 → null（跟随默认）。
/// - [audioStreamCount] 已知且 `index >= count` → null。即便有尾随 `?` 兜底硬失败，
///   越界的显式 `-map` 也会让 ffmpeg 静默挑错轨/丢音；越界时干脆不加 `-map`，
///   回退默认轨更可预测。count 为 null（未知真实流数）时不在此层拦，交给 `?` 兜底。
/// - 其余 → index 原样。
int? resolveAudioMapIndex({
  required int? audioStreamIndex,
  required int? audioStreamCount,
}) {
  if (audioStreamIndex == null || audioStreamIndex < 0) return null;
  if (audioStreamCount != null && audioStreamIndex >= audioStreamCount) {
    return null;
  }
  return audioStreamIndex;
}

Future<VideoClipExportResult> exportVideoClipViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final File output = File(outputPath);
  if (endMs <= startMs) {
    _deleteIfPresent(output);
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.invalidRange,
    );
  }
  if (!File(inputPath).existsSync()) {
    _deleteIfPresent(output);
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.inputMissing,
    );
  }

  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result =
        await (backend ?? resolveFfmpegBackend()).run(
      buildFfmpegVideoClipExportArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
      ),
      timeout,
    );
    if (result.isSuccess && output.existsSync() && output.lengthSync() > 0) {
      return VideoClipExportResult.success(outputPath);
    }
    _deleteIfPresent(output);
    if (result.isSuccess) {
      return const VideoClipExportResult.failure(
        VideoClipExportFailure.outputMissing,
      );
    }
    // C 修（BUG-345）：把 ffmpeg 真实失败原因（退出码 + stderr）写进错误日志，
    // 与 desktop_audio_clipper 的 _reportFfmpegFailure 对齐——否则失败是黑盒，
    // 真机只看到一句固定文案，看不到「Stream map matches no streams」。
    ErrorLogService.instance.log('VideoClipExport', result.failureSummary);
    // TODO-910：detail 回传 stderr **尾段**抽出的真因行，而非全量 stderr。
    // ffmpeg stderr 开头恒是 `Input #0, ...: Metadata: encoder :...` 输入 banner，
    // 真正的失败行（Conversion failed / matches no streams / Could not open ...）
    // 出现在末尾；调用方用它拼 OSD 时绝不能从头截断，否则只显示 banner。
    final String reason = extractFfmpegFailureReason(result.output);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: reason.isEmpty ? null : reason,
    );
  } on ProcessException catch (e, stack) {
    _deleteIfPresent(output);
    ErrorLogService.instance.log(
      'VideoClipExport',
      describeFfmpegProcessException(e),
      stack,
    );
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegUnavailable,
      detail: e.message,
    );
  } catch (e, stack) {
    _deleteIfPresent(output);
    ErrorLogService.instance.log('VideoClipExport', e, stack);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: e.toString(),
    );
  }
}

/// 纯函数：从 ffmpeg 的 stderr 里抽取「真正的失败原因行」，给失败 OSD 显示。
///
/// 根因（TODO-910）：ffmpeg 的 stderr 开头**恒是输入 banner**——
/// `Input #0, matroska,webm, from '<path>': Metadata: encoder :...`
/// （`-hide_banner` 只去版本 banner，不去 `-i` 的输入/流信息）。真正的失败行
/// （`Conversion failed!` / `Stream map '0:a:3' matches no streams` /
/// `Could not open file` / `Invalid data found` 等）出现在 stderr **末尾**。
/// 旧 OSD 用 `substring(0, 160)` 从头截断 → 用户只看到没用的输入 banner，
/// 看不到真因。本函数从尾段抽真因，让失败提示可读。
///
/// 策略（从尾往头扫，跳过 banner/进度/Metadata 噪声行）：
/// 1. 把 stderr 拆成非空行（去掉行内首尾空白）。
/// 2. **优先**：自尾向首找第一条「含错误关键词」的行
///    （error / failed / invalid / could not / no such / matches no streams /
///     unable / permission denied / not found），返回它。
/// 3. **退化**：没有任何错误关键词行（如只有 banner），返回**最后一条非噪声行**
///    （跳过 `Input #` / `Metadata:` / `Stream #` / `Duration:` / `encoder` /
///     纯进度 `frame=...` 这类信息行）；若全是噪声，返回最后一条非空行。
/// 4. 全空 → 空串（调用方据此不追加 detail）。
String extractFfmpegFailureReason(String stderr) {
  final List<String> lines = stderr
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';

  const List<String> errorMarkers = <String>[
    'error',
    'failed',
    'invalid',
    'could not',
    'cannot',
    'no such',
    'matches no streams',
    'unable',
    'permission denied',
    'not found',
    'unsupported',
    'unrecognized',
    'does not contain',
  ];
  for (int i = lines.length - 1; i >= 0; i--) {
    final String lower = lines[i].toLowerCase();
    if (errorMarkers.any(lower.contains)) {
      return lines[i];
    }
  }

  // 退化：无错误关键词（典型是被截断的纯 banner）。返回最后一条非噪声信息行。
  bool isNoise(String line) {
    final String lower = line.toLowerCase();
    return line.startsWith('Input #') ||
        line.startsWith('Output #') ||
        line.startsWith('Stream #') ||
        line.startsWith('Metadata:') ||
        line.startsWith('Duration:') ||
        lower.startsWith('frame=') ||
        lower.startsWith('size=') ||
        lower.contains('encoder') ||
        lower.startsWith('built with') ||
        lower.startsWith('configuration:') ||
        lower.startsWith('lib');
  }

  for (int i = lines.length - 1; i >= 0; i--) {
    if (!isNoise(lines[i])) return lines[i];
  }
  return lines.last;
}

void _deleteIfPresent(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
