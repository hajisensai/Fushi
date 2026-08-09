import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

void main() {
  test('resource info-hash dedupe prefers provider priority before seeders',
      () {
    final List<VideoResourceCandidate> result = deduplicateVideoResources(
      <VideoResourceCandidate>[
        _ResourceCandidate(priority: 200, seeders: 500),
        _ResourceCandidate(priority: 100, seeders: 5),
      ],
    );

    expect(result, hasLength(1));
    expect(result.single.providerPriority, 100);
    expect(result.single.seeders, 5);
  });

  test('subtitle dedupe prefers priority and returns priority order', () {
    final List<VideoSubtitleCandidate> result = deduplicateVideoSubtitles(
      <VideoSubtitleCandidate>[
        _SubtitleCandidate(id: 'same', priority: 200, downloads: 500),
        _SubtitleCandidate(id: 'same', priority: 100, downloads: 5),
        _SubtitleCandidate(id: 'other', priority: 50, downloads: 1),
      ],
    );

    expect(result, hasLength(2));
    expect(result.first.remoteId, 'other');
    expect(result.last.providerPriority, 100);
  });
}

class _ResourceCandidate extends VideoResourceCandidate {
  _ResourceCandidate({required int priority, required int seeders})
      : super(
          providerId: 'test',
          providerInstanceId: '$priority',
          remoteId: '$priority',
          title: 'Release',
          providerPriority: priority,
          infoHash: '0123456789abcdef0123456789abcdef01234567',
          seeders: seeders,
        );
}

class _SubtitleCandidate extends VideoSubtitleCandidate {
  _SubtitleCandidate({
    required String id,
    required int priority,
    required int downloads,
  }) : super(
          providerId: 'test',
          remoteId: id,
          fileName: '$id.srt',
          language: 'ja',
          providerPriority: priority,
          downloadCount: downloads,
        );
}
