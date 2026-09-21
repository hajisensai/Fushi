import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/download/video_download_subtitle_language.dart';

void main() {
  group('videoDownloadCollectionName', () {
    test('appends the year when present and not legacy', () {
      expect(
        videoDownloadCollectionName(title: 'Show', year: 2026),
        'Show (2026)',
      );
    });

    test('is the bare title without a year', () {
      expect(videoDownloadCollectionName(title: 'Show'), 'Show');
    });

    test('is the bare title for legacy jobs even with a year', () {
      expect(
        videoDownloadCollectionName(title: 'Show', year: 2026, legacy: true),
        'Show',
      );
    });
  });

  group('videoDownloadSeriesKey', () {
    test('lower-cases and trims the persisted collection name', () {
      expect(videoDownloadSeriesKey(title: ' Show', year: 2026), 'show (2026)');
      expect(videoDownloadSeriesKey(title: 'SHOW '), 'show');
    });

    test('is derived from the exact collection name the import stage uses', () {
      expect(
        videoDownloadSeriesKey(title: 'Show', year: 2026),
        videoDownloadCollectionName(title: 'Show', year: 2026)
            .trim()
            .toLowerCase(),
      );
    });
  });

  test('query exposes the same series key', () {
    const VideoDownloadSubtitleLanguageQuery query =
        VideoDownloadSubtitleLanguageQuery(
      jobId: 'job',
      title: 'Show',
      year: 2026,
    );
    expect(query.seriesKey, 'show (2026)');
  });
}
