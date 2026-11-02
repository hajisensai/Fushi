/// 版本组代表文件的正文语言探测（增强信息，绝不阻塞、绝不抛）。
///
/// 文件名认不出语言的版本组，下载其代表文件（字幕通常几十 KB）解码后用
/// [detectSubtitleContentLanguage] 判正文语言。结果只用于展示（「正文：简体
/// 中文」），不改变分组——探测是异步补充，卡片不因它重排。
///
/// 纪律（对来源站的礼貌，参照 RSS-Subtitle-Manager 的 4 并发 + 缓存）：
/// 结果按 identityKey 进程内缓存；超过 [maxProbeBytes] 的文件不探（整季包
/// 没必要为标签下几 MB）；任何失败静默返回 null。
library;

import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;

import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// 批量选字幕前，把**文件名认不出语言**的版本按正文判出语言（BUG-3993）。
///
/// 整批版本排名第一位是语言；文件名不带语言标记（`[shincaps] … - 01.ass`）
/// 不等于语言未知——正文就在那里。每个未标语言的版本只下一个代表文件（优先
/// 覆盖 [targetEpisodes] 的那个），解码后 [detectSubtitleContentLanguage]，
/// 结论投影成粗码（[coarseLanguageCode]）作用于整个版本。
///
/// [fetch] 由调用方提供并**自行缓存**：探过的文件若最终被选中，不应再下第二次。
/// 单个版本探测失败（网络 / 解码 / 正文判不出）只让那个版本保持未知，不影响其余。
/// 返回 版本键 → 粗语言码（只含判出来的版本）。
Future<Map<String, String>> probeUnlabeledVersionLanguages<T>({
  required Iterable<T> files,
  required Iterable<int> targetEpisodes,
  required String Function(T) versionOf,
  required String? Function(T) declaredLanguageOf,
  required int? Function(T) episodeOf,
  required Future<Uint8List?> Function(T) fetch,
}) async {
  final Set<int> targets = targetEpisodes.toSet();
  final Map<String, T> representative = <String, T>{};
  for (final T file in files) {
    final String? declared = declaredLanguageOf(file);
    if (declared != null && declared.isNotEmpty) continue;
    final String version = versionOf(file);
    final T? current = representative[version];
    final int? episode = episodeOf(file);
    final bool inTargets = episode != null && targets.contains(episode);
    if (current == null) {
      representative[version] = file;
    } else if (inTargets) {
      final int? currentEpisode = episodeOf(current);
      if (currentEpisode == null || !targets.contains(currentEpisode)) {
        representative[version] = file;
      }
    }
  }
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<String, T> entry in representative.entries) {
    try {
      final Uint8List? bytes = await fetch(entry.value);
      if (bytes == null || bytes.isEmpty) continue;
      final String? code = coarseLanguageCode(
        detectSubtitleContentLanguage(await decodeTextBytes(bytes)),
      );
      if (code != null) out[entry.key] = code;
    } on Object {
      continue; // 该版本保持未知，其余照探。
    }
  }
  return out;
}

class SubtitleVersionLanguageProbe {
  SubtitleVersionLanguageProbe({
    required Future<VideoSubtitleDownload> Function(
      VideoSubtitleCandidate candidate,
    )
    download,
    this.maxProbeBytes = 2 * 1024 * 1024,
  }) : _download = download;

  final Future<VideoSubtitleDownload> Function(VideoSubtitleCandidate candidate)
  _download;
  final int maxProbeBytes;

  final Map<String, SubtitleContentLanguage?> _cache =
      <String, SubtitleContentLanguage?>{};

  /// 探测 [candidate] 的正文语言；不可用/失败/unknown → null。
  Future<SubtitleContentLanguage?> probe(
    VideoSubtitleCandidate candidate,
  ) async {
    final String key = candidate.identityKey;
    if (_cache.containsKey(key)) return _cache[key];
    final int? size = candidate.fileSize;
    if (size != null && size > maxProbeBytes) {
      return _cache[key] = null;
    }
    try {
      final VideoSubtitleDownload download = await _download(candidate);
      if (download.bytes.isEmpty || download.bytes.length > maxProbeBytes) {
        return _cache[key] = null;
      }
      final String text = await decodeTextBytes(download.bytes);
      final SubtitleContentLanguage detected = detectSubtitleContentLanguage(
        text,
      );
      return _cache[key] = detected == SubtitleContentLanguage.unknown
          ? null
          : detected;
    } on Object {
      return _cache[key] = null;
    }
  }
}
