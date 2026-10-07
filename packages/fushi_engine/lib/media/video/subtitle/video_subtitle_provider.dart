import 'dart:typed_data';

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

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

/// 来源对「这条字幕属于哪部作品」的**自述**（BUG-3068）。
///
/// 字幕候选此前只带文件名与集号，作品身份全靠「搜索词搜得到它」隐式担保——而
/// Jimaku / AJATT 的标题搜索是模糊的、OpenSubtitles 的 moviehash 会撞车，于是
/// 「映画ドラえもん のび太と鉄人兵団」(1986) 被装上 2011 年重制版「新・…」的字幕，
/// 电影被装上同名 TV 系列某一集、甚至毫不相干的剧集。把来源自己知道的身份（条目
/// 名、年份、电影/剧集、外部 id）带出来，调用方才能拿它与目标作品比对、拒收错作品。
///
/// 全部字段可空 / 可空列表：来源不知道的就不说，**不知道 ≠ 不匹配**。
class SubtitleWorkClaim {
  SubtitleWorkClaim({
    Iterable<String> titles = const <String>[],
    this.year,
    this.kind,
    this.anilistId,
    this.tmdbId,
    this.imdbId,
  }) : titles = List<String>.unmodifiable(
          titles.where((String title) => title.trim().isNotEmpty),
        );

  /// 来源给这部作品的名字（条目名 / 日文名 / 英文名 / 特征标题），去空。
  final List<String> titles;

  /// 来源标注的作品年份。
  final int? year;

  /// 电影还是剧集；来源没明说为 null。
  final VideoMetadataMediaKind? kind;

  final int? anilistId;

  /// TMDB id，号段由 [kind] 决定（电影与剧集是两个独立号段）；[kind] 为 null 时
  /// 不可比。
  final int? tmdbId;

  /// IMDb id（`tt` 前缀可有可无）。
  final String? imdbId;
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
    this.archiveFormat,
    this.work,
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

  /// 非 null = 这条候选是一个**整季压缩包**（一个下载里装着多集），值是包格式。
  /// 包本身没有集号（[episode] 为 null）；单集下载由 provider 按请求集号从包内挑，
  /// 合集批量下载一次后按 [VideoSubtitleDownload.archiveEntries] 逐集拆分。
  /// [SubtitleArchiveFormat.isSupported] 为 false 的（RAR / 7z）照样列出来——
  /// 让用户看见「有，但解不开」，而不是静默丢掉。
  final SubtitleArchiveFormat? archiveFormat;

  /// 是否整季压缩包（见 [archiveFormat]）。
  bool get isArchivePack => archiveFormat != null;

  /// 来源自述的作品身份（见 [SubtitleWorkClaim]）；来源什么都不知道为 null。
  final SubtitleWorkClaim? work;

  String get identityKey => '$providerId:$remoteId';
}

class VideoSubtitleDownload {
  VideoSubtitleDownload({
    required Uint8List bytes,
    required this.fileName,
    required this.language,
    List<ArchivedSubtitle> archiveEntries = const <ArchivedSubtitle>[],
  })  : bytes = Uint8List.fromList(bytes),
        archiveEntries = List<ArchivedSubtitle>.unmodifiable(archiveEntries);

  final Uint8List bytes;
  final String fileName;
  final String language;

  /// 下载的是整季压缩包时，包内**全部**文本字幕（[bytes] / [fileName] 是按请求
  /// 集号挑出的那一个）。合集批量下载拿它逐集拆分，不必每集重下一次整包。
  /// 非压缩包下载恒为空。
  final List<ArchivedSubtitle> archiveEntries;
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
