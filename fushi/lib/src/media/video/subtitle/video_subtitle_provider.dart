import 'dart:typed_data';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';

class LocalVideoFingerprint {
  const LocalVideoFingerprint({
    required this.fileSize,
    this.openSubtitlesMovieHash,
    this.fileName,
  });

  final int fileSize;
  final String? openSubtitlesMovieHash;
  final String? fileName;
}

class VideoSubtitleSearchRequest {
  VideoSubtitleSearchRequest({
    this.media,
    this.query,
    Iterable<String> alternateTitles = const <String>[],
    Iterable<String> languages = const <String>[],
    this.season,
    this.episode,
    this.fingerprint,
    this.page = 1,
    this.anime,
  })  : alternateTitles = List<String>.unmodifiable(alternateTitles),
        languages = List<String>.unmodifiable(languages),
        assert(page > 0);

  final VideoMediaReference? media;
  final String? query;
  final List<String> alternateTitles;
  final List<String> languages;
  final int? season;
  final int? episode;
  final LocalVideoFingerprint? fingerprint;
  final int page;

  /// 内容类型提示（目前只有 Jimaku 消费）：Jimaku 的 `anime` 是硬相等过滤且服务端默认
  /// true——真人剧/日剧必须显式 false 才搜得到。null = 不带参数（旧行为，只搜番剧）。
  final bool? anime;

  String get effectiveQuery => query?.trim().isNotEmpty == true
      ? query!.trim()
      : media?.title.trim() ?? '';
  int? get effectiveSeason => season ?? media?.season;
  int? get effectiveEpisode => episode ?? media?.episode;
}

abstract class VideoSubtitleCandidate {
  VideoSubtitleCandidate({
    required this.providerId,
    required this.remoteId,
    required this.fileName,
    required this.language,
    required this.providerPriority,
    this.releaseName,
    this.season,
    this.episode,
    this.fileSize,
    this.downloadCount = 0,
    this.hearingImpaired = false,
    this.fps,
    this.uploadedAtMs,
    this.collectionId,
    this.collectionLabel,
    this.aiTranslated = false,
    this.fromTrusted = false,
  });

  final String providerId;
  final String remoteId;
  final String fileName;
  final String language;
  final int providerPriority;
  final String? releaseName;
  final int? season;
  final int? episode;
  final int? fileSize;
  final int downloadCount;
  final bool hearingImpaired;
  final double? fps;

  /// 上传/最后修改时刻（epoch 毫秒）。版本选择器的「N 天前」与「最新文件」
  /// 判定用；来源没给（旧响应）为 null。
  final int? uploadedAtMs;

  /// 来源侧的「合集」身份（Jimaku entry id / OpenSubtitles 无此概念为 null）。
  /// 两级版本聚类的第一级分组键；此前只藏在 remoteId 前缀里，UI 拿不到。
  final String? collectionId;

  /// [collectionId] 的展示名（Jimaku entry 名）。
  final String? collectionLabel;

  /// 来源明确标注的机翻（OpenSubtitles `ai_translated`）。质量信号，排序降权。
  final bool aiTranslated;

  /// 来源明确标注的可信上传者（OpenSubtitles `from_trusted`）。
  final bool fromTrusted;

  String get identityKey => '$providerId:$remoteId';
}

class VideoSubtitleDownload {
  VideoSubtitleDownload({
    required Uint8List bytes,
    required this.fileName,
    required this.language,
  }) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final String fileName;
  final String language;
}

abstract interface class VideoSubtitleProvider {
  String get id;

  /// Lower values run first and win provider-local tie breaks.
  int get priority;

  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  );

  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate);

  /// 是否允许为「正文语言探测」这类**展示增强**目的白下载一次。
  ///
  /// 默认必须是 false。有下载配额的源（OpenSubtitles 的 `/download` 就是计配额的那
  /// 一步，响应里带 `remaining`）绝不能被后台探测消耗——免费账号一天只有 5~20 次，
  /// 一次搜索最多能吞掉 4 次，而探测失败还被静默吞掉，用户只会看到「下载失败」，
  /// 永远不知道配额是被一个标签吃光的。判据必须是「这个源有没有配额」，不能是
  /// 「这条候选的 language 字段是不是空的」——后者与配额毫无关系。
  bool get allowsFreeProbeDownload;

  void close();
}

List<VideoSubtitleCandidate> deduplicateVideoSubtitles(
  Iterable<VideoSubtitleCandidate> candidates,
) {
  final Map<String, VideoSubtitleCandidate> unique =
      <String, VideoSubtitleCandidate>{};
  for (final VideoSubtitleCandidate candidate in candidates) {
    final VideoSubtitleCandidate? existing = unique[candidate.identityKey];
    if (existing == null ||
        candidate.providerPriority < existing.providerPriority ||
        (candidate.providerPriority == existing.providerPriority &&
            candidate.downloadCount > existing.downloadCount)) {
      unique[candidate.identityKey] = candidate;
    }
  }
  final List<VideoSubtitleCandidate> sorted = unique.values.toList()
    ..sort((VideoSubtitleCandidate a, VideoSubtitleCandidate b) {
      final int byPriority = a.providerPriority.compareTo(b.providerPriority);
      return byPriority != 0
          ? byPriority
          : b.downloadCount.compareTo(a.downloadCount);
    });
  return List<VideoSubtitleCandidate>.unmodifiable(sorted);
}
