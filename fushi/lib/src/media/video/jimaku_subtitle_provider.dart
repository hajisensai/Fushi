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

  /// 把发现层的分类映射成 Jimaku 的检索范围。
  ///
  /// Jimaku 站点把动画与真人拆成两个互斥集合（`anime` 是硬相等过滤），所以这里必须给出
  /// 明确范围而不能"都不说"——不说等于只搜动画。分类未知（无 media 引用，例如播放页对
  /// 一个本地文件搜字幕）时取 [JimakuSearchScope.all]：宁可多发一次请求，也不要因为默
  /// 认动画而把日剧字幕整片藏起来。
  static JimakuSearchScope scopeFor(VideoMediaReference? media) {
    if (media == null) return JimakuSearchScope.all;
    return media.discoveryCategory == VideoDiscoveryCategory.anime
        ? JimakuSearchScope.anime
        : JimakuSearchScope.liveAction;
  }

  /// 把发现层的裸 TMDB 数字 id 编码成 Jimaku 的 `tv:<id>` / `movie:<id>`。
  ///
  /// TMDB 的电影与剧集是两个独立号段，媒体种类必须一起编码，否则会张冠李戴。
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
        tmdbId: tmdbIdFor(request.media),
        queryFallbacks: fallbacks,
        scope: scopeFor(request.media),
        throwOnError: true,
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
