/// 探一个本地视频文件的容器时长（毫秒）。
///
/// 存在的唯一理由：字幕落盘前要用它做「这条字幕真的是这个视频的吗」校验
/// （见 `subtitle/subtitle_timing_check.dart`）。`VideoBooks` 没有 duration 列，
/// 播放器的时长又只在 controller 打开后才有——下载流水线拿不到，只能现探。
///
/// 走既有 [FfmpegBackend.runProbe]，所以桌面（ffprobe 进程）与移动端
/// （ffmpeg-kit 进程内）同一条路径，不新增平台分支。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'package:fushi/src/media/video/ffmpeg_backend.dart';

/// ffprobe 探时长的超时。只读 header，不解码，几十毫秒级；给足 20s 覆盖冷缓存
/// 与机械盘。**超时按失败处理并返回 null**——校验拿不到时长时会退化成「只做内容
/// 自检」，绝不因为探测失败就拒收字幕。
const Duration kVideoDurationProbeTimeout = Duration(seconds: 20);

/// 返回 [path] 的时长毫秒；探不到返回 null（缺 ffprobe / 超时 / 不是媒体文件）。
Future<int?> probeVideoDurationMs(
  String path, {
  @visibleForTesting FfmpegBackend? backend,
}) async {
  try {
    final FfmpegRunResult result =
        await (backend ?? resolveFfmpegBackend()).runProbe(
      <String>[
        '-v',
        'quiet',
        '-print_format',
        'json',
        '-show_entries',
        'format=duration',
        path,
      ],
      kVideoDurationProbeTimeout,
    );
    if (result.returnCode != 0) return null;
    return parseFfprobeDurationMs(result.output);
  } catch (e) {
    // 缺 ffprobe 是**正常降级**（用户没装 / 没捆绑），不是错误路径。
    debugPrint('[VideoDurationProbe] duration probe failed for "$path": $e');
    return null;
  }
}

/// 从 ffprobe `-print_format json -show_entries format=duration` 的 stdout 解析
/// 时长毫秒。纯函数，便于单测。
///
/// ffprobe 对无时长容器会给 `"N/A"` 或干脆不给 `duration` 字段，两种都返回 null。
int? parseFfprobeDurationMs(String stdout) {
  final String trimmed = stdout.trim();
  if (trimmed.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;
    final Object? format = decoded['format'];
    if (format is! Map<String, dynamic>) return null;
    final Object? duration = format['duration'];
    final double? seconds = switch (duration) {
      final num value => value.toDouble(),
      final String value => double.tryParse(value),
      _ => null,
    };
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return (seconds * 1000).round();
  } catch (_) {
    return null;
  }
}
