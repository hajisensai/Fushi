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
