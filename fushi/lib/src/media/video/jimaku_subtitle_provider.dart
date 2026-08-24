import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

class JimakuVideoSubtitleProvider implements VideoSubtitleProvider {
  JimakuVideoSubtitleProvider({
    required JimakuClient client,
    this.priority = 100,
    bool closesClient = false,
  })  : _client = client,
        _closesClient = closesClient;

  final JimakuClient _client;
  final bool _closesClient;

  @override
  final int priority;

  @override
  String get id => 'jimaku';

  /// 把发现层的裸 TMDB 数字 id 编码成 Jimaku 的 `tv:<id>` / `movie:<id>`（BUG-1849）。
  ///
  /// TMDB 的电影与剧集是两个独立号段，媒体种类必须一起编码，否则会张冠李戴。
  /// 分类过滤（[JimakuAnimeFilter]）与检索键是正交两件事：这里只负责后者。
  static String? tmdbIdFor(VideoMediaReference? media) {
    final int? tmdbId = media?.tmdbId;
    if (tmdbId == null) return null;
    return jimakuTmdbId(
      movie: media!.mediaKind == VideoMetadataMediaKind.movie,
      tmdbId: tmdbId,
    );
  }

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    final List<String> fallbacks = <String>{
      request.effectiveQuery,
      ...request.alternateTitles,
      if (request.media?.originalTitle != null) request.media!.originalTitle!,
    }.where((String title) => title.trim().isNotEmpty).toList();
    try {
      final List<JimakuEntry> entries = await _client.searchEntries(
        anilistId: request.media?.anilistId,
        // 真人剧的权威关联键：AniList 只覆盖动画，没有它就只能拿显示名去模糊碰（BUG-1849）。
        tmdbId: tmdbIdFor(request.media),
        queryFallbacks: fallbacks,
        // Jimaku 的 anime 过滤是硬相等且服务端默认 true：真人剧必须显式 false 才搜得到。
        // 三态由请求方（扩展桥/未来的 UI 开关）经 [_animeFilterFor] 决定——曾经这里
        // 同时传 bool `anime:` 与 animeFilter 两个参数，而分流只看后者，前者传了不生效。
        throwOnError: true,
        animeFilter: _animeFilterFor(request),
      );
      final List<VideoSubtitleCandidate> candidates =
          <VideoSubtitleCandidate>[];
      for (final JimakuEntry entry in entries) {
        final List<JimakuFile> files = await _client.listFiles(
          entry.id,
          episode: request.effectiveEpisode,
          throwOnError: true,
        );
        for (final JimakuFile file in files) {
          if (!file.isTextSubtitle) continue;
          final String language = detectSubtitleLanguage(file.name) ?? '';
          if (request.languages.isNotEmpty &&
              !request.languages.contains(language)) {
            continue;
          }
          candidates.add(
            _JimakuSubtitleCandidate(
              entry: entry,
              file: file,
              language: language,
              season: request.effectiveSeason,
              providerPriority: priority,
            ),
          );
        }
      }
      return ProviderBatchResult<VideoSubtitleCandidate>.success(candidates);
    } on Object catch (error) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        _jimakuFailure('search', error),
      );
    }
  }

  @override

  /// Jimaku 无下载配额概念，允许为语言标签白下一次。
  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    if (candidate is! _JimakuSubtitleCandidate) {
      throw const ExternalProviderFailure(
        providerId: 'jimaku',
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    try {
      final bytes = await _client.downloadFile(
        candidate.file.url,
        throwOnError: true,
      );
      if (bytes == null || bytes.isEmpty) {
        throw const ExternalProviderFailure(
          providerId: 'jimaku',
          operation: 'download',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'subtitle download failed',
          retryable: true,
        );
      }
      return VideoSubtitleDownload(
        bytes: bytes,
        fileName: candidate.file.name,
        language: candidate.language,
      );
    } on Object catch (error) {
      throw _jimakuFailure('download', error);
    }
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// 把发现层的分类映射成 Jimaku 的 `anime` 硬过滤（BUG-1694）。
///
/// `discoveryCategory` 已经是这个问题的答案，不需要再猜：anime → 只搜动画；
/// movie/tv → 只搜真人；连 media 都没有（纯文本搜索请求）才两档都试。
JimakuAnimeFilter _animeFilterFor(VideoSubtitleSearchRequest request) {
  return switch (request.media?.discoveryCategory) {
    VideoDiscoveryCategory.anime => JimakuAnimeFilter.anime,
    VideoDiscoveryCategory.movie ||
    VideoDiscoveryCategory.tv =>
      JimakuAnimeFilter.liveAction,
    null => JimakuAnimeFilter.either,
  };
}

class _JimakuSubtitleCandidate extends VideoSubtitleCandidate {
  _JimakuSubtitleCandidate({
    required this.entry,
    required this.file,
    required String language,
    required int? season,
    required int providerPriority,
  }) : super(
          providerId: 'jimaku',
          remoteId: '${entry.id}:${file.name}',
          fileName: file.name,
          language: language,
          providerPriority: providerPriority,
          releaseName: entry.name,
          season: season,
          episode: file.episode,
          fileSize: file.size,
          uploadedAtMs: file.lastModifiedMs,
          collectionId: '${entry.id}',
          collectionLabel: entry.name,
        );

  final JimakuEntry entry;
  final JimakuFile file;
}

ExternalProviderFailure _jimakuFailure(String operation, Object error) {
  if (error is! JimakuRequestException) {
    return ExternalProviderFailure.fromException(
      providerId: 'jimaku',
      operation: operation,
      error: error,
    );
  }
  final int? status = error.statusCode;
  return ExternalProviderFailure(
    providerId: 'jimaku',
    operation: operation,
    kind: switch (status) {
      401 => ExternalProviderFailureKind.unauthorized,
      403 => ExternalProviderFailureKind.forbidden,
      429 => ExternalProviderFailureKind.rateLimited,
      _ => status == null
          ? ExternalProviderFailureKind.invalidResponse
          : ExternalProviderFailureKind.unavailable,
    },
    message: status == null
        ? 'Jimaku returned an invalid response'
        : 'Jimaku returned HTTP $status',
    statusCode: status,
    retryable: status == 429 || (status != null && status >= 500),
  );
}
