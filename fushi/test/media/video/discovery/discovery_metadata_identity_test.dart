import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/discovery/discovery_metadata_identity.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_media_reference_codec.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';

VideoMediaReference _reference({
  String provider = 'anilist',
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  Map<String, String> ids = const <String, String>{},
}) =>
    VideoMediaReference(
      providerId: provider,
      mediaId: '86',
      mediaKind: kind,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: '86',
      externalIds: ids,
    );

void main() {
  test('AniList MAL cross ID survives download snapshot and wins over TMDB',
      () {
    final VideoMediaReference reference = _reference(ids: <String, String>{
      'mal': '41457',
      'tmdb': '100565',
      'anidb': '15441',
    });
    final VideoMediaReference restored =
        decodeVideoMediaReference(encodeVideoMediaReference(reference))!;
    final VideoMetadataLookup lookup = videoDiscoveryMetadataLookup(restored)!;
    expect(lookup.provider, VideoMetadataProviderKind.mal);
    expect(lookup.externalId, '41457');
  });

  test('TMDB fallback retains movie and TV namespaces', () {
    for (final VideoMetadataMediaKind kind in <VideoMetadataMediaKind>[
      VideoMetadataMediaKind.movie,
      VideoMetadataMediaKind.tv,
    ]) {
      final VideoMetadataLookup lookup = videoDiscoveryMetadataLookup(
        _reference(kind: kind, ids: <String, String>{'tmdb': '42'}),
      )!;
      expect(lookup.provider, VideoMetadataProviderKind.tmdb);
      expect(lookup.mediaKind, kind);
      expect(lookup.externalId, '42');
    }
  });

  test('numeric title and AniDB ID cannot masquerade as MAL work identity', () {
    expect(videoDiscoveryMetadataLookup(_reference()), isNull);
    expect(
        videoDiscoveryMetadataLookup(
            _reference(ids: <String, String>{'anidb': '42', 'mal': '0'})),
        isNull);
    expect(
        videoDiscoveryMetadataLookup(_reference(provider: 'mal'))?.externalId,
        '86');
  });
}
