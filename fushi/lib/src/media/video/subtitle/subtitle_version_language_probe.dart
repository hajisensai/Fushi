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

/// 批量选字幕前，把**文件名认不出语言**的版本按正文判出语言（BUG-3998）。
///
/// 整批版本排名第一位是语言；文件名不带语言标记（`[shincaps] … - 01.ass`）
/// 不等于语言未知——正文就在那里。每个未标语言的版本只下一个代表文件，解码后
/// [detectSubtitleContentLanguage]，结论作用于整个版本。
///
/// 代表文件只从**集号落在 [targetEpisodes] 里**的文件中挑：一集目标都不覆盖的
/// 版本（别季、剧场版、未编号单文件）永远不会被选给任何目标集，它的语言排名对
/// 结果没有影响，不值得为它下载。批量编排、合集面板、番剧下载三处共用这一个判据。
///
/// [fetch] 由调用方提供并**自行缓存**：探过的文件若最终被选中，不应再下第二次。
/// 超过 [maxProbeBytes] 的文件不探（[sizeOf] 已知时下载前就跳过）。单个版本失败
/// 不影响其余。
///
/// 返回 版本键 → 正文语言；**键在 = 已有结论**：下到了正文但判不出 / 解不开 / 超限
/// 的版本值为 null，调用方据此不再重探。**下载失败（抛错 / 空字节）不入表**——那是
/// 暂时性失败（调用方的下载缓存同样会把失败的下载移出），留给下一次探测重试；若记成
/// null，一次网络抖动就会让该版本在本面板 / 本批里永远按「语言未知」排名。[onProbed] 每探完一个版本回调一次
/// （面板逐个回填）；[isCancelled] 返回 true 时停止后续探测。
Future<Map<String, SubtitleContentLanguage?>>
probeUnlabeledVersionLanguages<T>({
  required Iterable<T> files,
  required Iterable<int> targetEpisodes,
  required String Function(T) versionOf,
  required String? Function(T) declaredLanguageOf,
  required int? Function(T) episodeOf,
  required Future<Uint8List?> Function(T) fetch,
  int? Function(T)? sizeOf,
  int maxProbeBytes = kSubtitleProbeMaxBytes,
  void Function(String version, SubtitleContentLanguage? language)? onProbed,
  bool Function()? isCancelled,
}) async {
  final Set<int> targets = targetEpisodes.toSet();
  final Map<String, T> representative = <String, T>{};
  for (final T file in files) {
    final String? declared = declaredLanguageOf(file);
    if (declared != null && declared.isNotEmpty) continue;
    final int? episode = episodeOf(file);
    if (episode == null || !targets.contains(episode)) continue;
    representative.putIfAbsent(versionOf(file), () => file);
  }
  final Map<String, SubtitleContentLanguage?> out =
      <String, SubtitleContentLanguage?>{};
  for (final MapEntry<String, T> entry in representative.entries) {
    if (isCancelled?.call() ?? false) break;
    final ({bool concluded, SubtitleContentLanguage? language}) result =
        await _probeOne(
          entry.value,
          fetch: fetch,
          sizeOf: sizeOf,
          maxProbeBytes: maxProbeBytes,
        );
    if (isCancelled?.call() ?? false) break;
    if (!result.concluded) continue; // 下载失败：不记为已探，下次重试。
    out[entry.key] = result.language;
    onProbed?.call(entry.key, result.language);
  }
  return out;
}

/// 探一个代表文件。`concluded` = false 表示下载失败（暂时性，不该记为已探）；
/// 其余情况（超限 / 调用方不给字节 / 解不开 / 判不出 / 判出）都是结论。
Future<({bool concluded, SubtitleContentLanguage? language})> _probeOne<T>(
  T file, {
  required Future<Uint8List?> Function(T) fetch,
  required int? Function(T)? sizeOf,
  required int maxProbeBytes,
}) async {
  const ({bool concluded, SubtitleContentLanguage? language}) unknown = (
    concluded: true,
    language: null,
  );
  final int? size = sizeOf?.call(file);
  if (size != null && size > maxProbeBytes) return unknown;
  final Uint8List? bytes;
  try {
    bytes = await fetch(file);
  } on Object {
    return (concluded: false, language: null);
  }
  if (bytes == null || bytes.length > maxProbeBytes) return unknown;
  if (bytes.isEmpty) return (concluded: false, language: null);
  try {
    final SubtitleContentLanguage detected = detectSubtitleContentLanguage(
      await decodeTextBytes(bytes),
    );
    return detected == SubtitleContentLanguage.unknown
        ? unknown
        : (concluded: true, language: detected);
  } on Object {
    return unknown; // 下到了但解不开：等同判不出，不再重探。
  }
}

/// 探测结果投影成批量排名用的粗码（只含判出来的版本）。
Map<String, String> coarseVersionLanguages(
  Map<String, SubtitleContentLanguage?> probed,
) => <String, String>{
  for (final MapEntry<String, SubtitleContentLanguage?> e in probed.entries)
    if (e.value != null && coarseLanguageCode(e.value!) != null)
      e.key: coarseLanguageCode(e.value!)!,
};

/// 正文探测的单文件上限：整季包没必要为一个标签下几 MB。
const int kSubtitleProbeMaxBytes = 2 * 1024 * 1024;

class SubtitleVersionLanguageProbe {
  SubtitleVersionLanguageProbe({
    required Future<VideoSubtitleDownload> Function(
      VideoSubtitleCandidate candidate,
    )
    download,
    this.maxProbeBytes = kSubtitleProbeMaxBytes,
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
