import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';

void main() {
  test('sparse overrides inherit global values and reject bad wire types', () {
    const MangaReaderPreferences global = MangaReaderPreferences(
      mode: MangaReadingMode.webtoonGaps,
      scaleType: MangaScaleType.fitWidth,
      direction: 'ltr',
      showPageNumber: false,
    );
    final MangaReaderPreferences resolved = MangaReaderPreferences.resolve(
      global,
      <String, Object?>{
        'longStripSidePadding': 12,
        'showPageNumber': true,
        'scaleType': 'unknown',
        'direction': 42,
      },
    );
    expect(resolved.mode, MangaReadingMode.webtoonGaps);
    expect(resolved.scaleType, MangaScaleType.fitWidth);
    expect(resolved.direction, 'ltr');
    expect(resolved.longStripSidePadding, 12);
    expect(resolved.showPageNumber, isTrue);
  });

  test('all six scale modes and old reading keys round-trip', () {
    for (final MangaScaleType scale in MangaScaleType.values) {
      final MangaReaderPreferences value = MangaReaderPreferences(
        scaleType: scale,
        mode: MangaReadingMode.pagedVertical,
      );
      final MangaReaderPreferences decoded =
          MangaReaderPreferences.fromJson(value.toJson());
      expect(decoded.scaleType, scale);
      expect(decoded.mode, MangaReadingMode.pagedVertical);
    }
    expect(
      MangaReadingModeSemantics.fromStorageKey('spread'),
      MangaReadingMode.spread,
    );
    expect(
      MangaReadingModeSemantics.fromStorageKey('webtoon'),
      MangaReadingMode.webtoon,
    );
  });
}
