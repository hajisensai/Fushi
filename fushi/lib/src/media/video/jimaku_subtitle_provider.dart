import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
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
        queryFallbacks: fallbacks,
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
