import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';

void main() {
  test('Mangatan controls round-trip and clamp untrusted persisted values', () {
    final MangaReaderPreferences value =
        MangaReaderPreferences.fromJson(<String, Object?>{
      'automaticBackground': true,
      'webtoonDoubleTapZoom': false,
      'showPageGaps': false,
      'autoScroll': true,
      'autoScrollSpeed': 999,
      'readerHideThreshold': -5,
      'einkMode': true,
      'lookupOnHover': true,
      'showOcrBoxes': true,
      'brightness': -500,
      'contrast': 900,
      'saturation': double.nan,
      'customColorFilter': true,
      'colorFilterColor': '#a0F15b',
      'colorFilterOpacity': 200,
      'ocrTrigger': 'manual',
      'parallelOcrTasks': 9,
    });
    expect(value.autoScrollSpeed, 200);
    expect(value.readerHideThreshold, 0);
    expect(value.brightness, -100);
    expect(value.contrast, 200);
    expect(value.saturation, 100);
    expect(value.colorFilterOpacity, 100);
    // 页级并发已随「边看边识别」移除：旧覆盖里残留的键只是死数据，读入即丢。
    expect(value.toJson().containsKey('parallelOcrTasks'), isFalse);
    expect(
      MangaReaderPreferences.fromJson(value.toJson()).toJson(),
      value.toJson(),
    );
    final MangaReaderPreferences resolved =
        value.copyWithJson(<String, Object?>{
      'colorFilterColor': '#fff;display:none',
      'ocrTrigger': 'eager',
      'autoScrollSpeed': double.infinity,
    });
    expect(resolved.colorFilterColor, '#a0F15b');
    expect(resolved.ocrTrigger, 'manual');
    expect(resolved.autoScrollSpeed, 200);
  });
  test('sparse overrides inherit global values and reject bad wire types', () {
    const MangaReaderPreferences global = MangaReaderPreferences(
      mode: MangaReadingMode.webtoonGaps,
      scaleType: MangaScaleType.fitWidth,
      direction: 'ltr',
      showPageNumber: false,
    );
    final MangaReaderPreferences resolved =
        MangaReaderPreferences.resolve(global, <String, Object?>{
      'longStripSidePadding': 12,
      'showPageNumber': true,
      'scaleType': 'unknown',
      'direction': 42,
    });
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
      final MangaReaderPreferences decoded = MangaReaderPreferences.fromJson(
        value.toJson(),
      );
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
