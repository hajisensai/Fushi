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

import 'package:fushi_audio/fushi_audio.dart' show decodeTextBytes;

import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

class SubtitleVersionLanguageProbe {
  SubtitleVersionLanguageProbe({
    required Future<VideoSubtitleDownload> Function(
      VideoSubtitleCandidate candidate,
    ) download,
    this.maxProbeBytes = 2 * 1024 * 1024,
  }) : _download = download;

  final Future<VideoSubtitleDownload> Function(
    VideoSubtitleCandidate candidate,
  ) _download;
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
      final SubtitleContentLanguage detected =
          detectSubtitleContentLanguage(text);
      return _cache[key] =
          detected == SubtitleContentLanguage.unknown ? null : detected;
    } on Object {
      return _cache[key] = null;
    }
  }
}
