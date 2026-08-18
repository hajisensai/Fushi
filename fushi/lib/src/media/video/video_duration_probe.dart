/// 探一个本地视频文件的两件事实：容器时长，与音轨自报的语言。
///
/// 存在的理由都在字幕自动获取链路上：
/// - **时长**给「这条字幕真的是这个视频的吗」校验用（`subtitle/subtitle_timing_check.dart`）。
///   `VideoBooks` 没有 duration 列，播放器时长又只在 controller 打开后才有，下载
///   流水线拿不到，只能现探。
/// - **音轨语言**给「默认下视频语言的字幕」用。它是「视频语言」最直接的一手来源，
///   而且**与时长同一次 ffprobe 就能拿到**——分两次探是白付一次进程/IO。
///
/// 走既有 [FfmpegBackend.runProbe]，所以桌面（ffprobe 进程）与移动端
/// （ffmpeg-kit 进程内）同一条路径，不新增平台分支。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'package:fushi/src/media/video/ffmpeg_backend.dart';

/// ffprobe 探测的超时。只读 header，不解码，几十毫秒级；给足 20s 覆盖冷缓存
/// 与机械盘。**超时按失败处理并返回空结果**——校验拿不到时长时会退化成「只做内容
/// 自检」，绝不因为探测失败就拒收字幕。
const Duration kVideoDurationProbeTimeout = Duration(seconds: 20);

/// 一次 ffprobe 的产出。两个字段各自可空：探到什么算什么，绝不因为一半缺失就把
/// 另一半也丢掉。
class VideoProbeFacts {
  const VideoProbeFacts(
      {this.durationMs, this.audioLanguages = const <String>[]});

  static const VideoProbeFacts empty = VideoProbeFacts();

  /// 容器时长（毫秒）；探不到为 null。
  final int? durationMs;

  /// 音轨自报的语言标签，**按流顺序**（第一条通常是主音轨）。未标注的流不入列。
  ///
  /// 原样返回不归一：归一是 `subtitle_language_preference.dart` 的职责，本模块
  /// 只负责「ffprobe 说了什么」。
  final List<String> audioLanguages;

  /// 主音轨语言（第一条带 language tag 的音轨）；没有返回 null。
  String? get primaryAudioLanguage =>
      audioLanguages.isEmpty ? null : audioLanguages.first;
}

/// 一次 ffprobe 拿到 [path] 的时长 + 音轨语言。任何失败返回 [VideoProbeFacts.empty]。
Future<VideoProbeFacts> probeVideoFacts(
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
        'format=duration:stream=index,codec_type:stream_tags=language',
        path,
      ],
      kVideoDurationProbeTimeout,
    );
    if (result.returnCode != 0) return VideoProbeFacts.empty;
    return parseFfprobeFacts(result.output);
  } catch (e) {
    // 缺 ffprobe 是**正常降级**（用户没装 / 没捆绑），不是错误路径。
    debugPrint('[VideoDurationProbe] probe failed for "$path": $e');
    return VideoProbeFacts.empty;
  }
}

/// 只要时长的窄入口（老调用点保持原样）。
Future<int?> probeVideoDurationMs(
  String path, {
  @visibleForTesting FfmpegBackend? backend,
}) async =>
    (await probeVideoFacts(path, backend: backend)).durationMs;

/// 解析 ffprobe `-print_format json` 的 stdout。纯函数，便于单测。
///
/// 容错到底：ffprobe 对无时长容器给 `"N/A"` 或干脆不给 `duration`；`streams` 可能
/// 整个缺失（`-show_entries` 只要了 format 时）；单个 stream 可能没有 `tags`。
/// 任何一处不合预期都只让那一项为空，**不让整次探测作废**。
VideoProbeFacts parseFfprobeFacts(String stdout) {
  final String trimmed = stdout.trim();
  if (trimmed.isEmpty) return VideoProbeFacts.empty;
  try {
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return VideoProbeFacts.empty;
    return VideoProbeFacts(
      durationMs: _durationMsFrom(decoded['format']),
      audioLanguages: _audioLanguagesFrom(decoded['streams']),
    );
  } catch (_) {
    return VideoProbeFacts.empty;
  }
}

/// 兼容老调用点/老测试：只取时长。
int? parseFfprobeDurationMs(String stdout) =>
    parseFfprobeFacts(stdout).durationMs;

int? _durationMsFrom(Object? format) {
  if (format is! Map<String, dynamic>) return null;
  final Object? duration = format['duration'];
  final double? seconds = switch (duration) {
    final num value => value.toDouble(),
    final String value => double.tryParse(value),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return (seconds * 1000).round();
}

List<String> _audioLanguagesFrom(Object? streams) {
  if (streams is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? stream in streams) {
    if (stream is! Map<String, dynamic>) continue;
    if (stream['codec_type'] != 'audio') continue;
    final Object? tags = stream['tags'];
    if (tags is! Map<String, dynamic>) continue;
    final Object? language = tags['language'];
    if (language is! String) continue;
    final String trimmed = language.trim();
    // `und` 是 ffmpeg 对「未标注」的显式写法，等同于没有——放行它会让下游把
    // 「未知」当成一个真语言去匹配，永远匹配不上，还挡住后面真有标注的音轨。
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'und') continue;
    out.add(trimmed);
  }
  return List<String>.unmodifiable(out);
}
