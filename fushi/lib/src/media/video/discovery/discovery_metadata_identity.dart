/// Exact discovery identities reused when downloaded files enter the library.
library;

import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

/// AniList discovery already supplies MAL's `idMal` in `externalIds`. Prefer
/// that identity without making a second fuzzy title search at download time.
/// TMDB's movie and TV namespaces remain distinct through `mediaKind`.
VideoMetadataLookup? videoDiscoveryMetadataLookup(
    VideoMediaReference reference) {
  String? positiveId(Object? value) {
    final int? id = int.tryParse(value?.toString().trim() ?? '');
    return id != null && id > 0 ? '$id' : null;
  }

  final String? malId = positiveId(reference.externalIds['mal']) ??
      (reference.providerId.toLowerCase() == 'mal'
          ? positiveId(reference.mediaId)
          : null);
  if (malId != null) {
    return VideoMetadataLookup(
      provider: VideoMetadataProviderKind.mal,
      externalId: malId,
      mediaKind: reference.mediaKind,
    );
  }
  final String? tmdbId = positiveId(reference.tmdbId) ??
      positiveId(reference.externalIds['tmdb']) ??
      (reference.providerId.toLowerCase() == 'tmdb'
          ? positiveId(reference.mediaId)
          : null);
  if (tmdbId == null) return null;
  return VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: tmdbId,
    mediaKind: reference.mediaKind,
  );
}
