/// Exact discovery identities reused when downloaded files enter the library.
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// AniList discovery already supplies MAL's `idMal` in `externalIds`. Prefer
/// that identity without making a second fuzzy title search at download time.
/// TMDB's movie and TV namespaces remain distinct through `mediaKind`.
VideoMetadataLookup? videoDiscoveryMetadataLookup(
        VideoMediaReference reference) =>
    videoDiscoveryMetadataLookups(reference).firstOrNull;

/// Every directly fetchable identity of [reference], preferred first (MAL,
/// then TMDB). A single source can be down (Jikan unreachable for days): the
/// others are the same work and must stay usable instead of being dropped
/// behind the first one (BUG-3073).
List<VideoMetadataLookup> videoDiscoveryMetadataLookups(
    VideoMediaReference reference) {
  String? positiveId(Object? value) {
    final int? id = int.tryParse(value?.toString().trim() ?? '');
    return id != null && id > 0 ? '$id' : null;
  }

  final String? malId = positiveId(reference.externalIds['mal']) ??
      (reference.providerId.toLowerCase() == 'mal'
          ? positiveId(reference.mediaId)
          : null);
  final String? tmdbId = positiveId(reference.tmdbId) ??
      positiveId(reference.externalIds['tmdb']) ??
      (reference.providerId.toLowerCase() == 'tmdb'
          ? positiveId(reference.mediaId)
          : null);
  return <VideoMetadataLookup>[
    if (malId != null)
      VideoMetadataLookup(
        provider: VideoMetadataProviderKind.mal,
        externalId: malId,
        mediaKind: reference.mediaKind,
      ),
    if (tmdbId != null)
      VideoMetadataLookup(
        provider: VideoMetadataProviderKind.tmdb,
        externalId: tmdbId,
        mediaKind: reference.mediaKind,
      ),
  ];
}
