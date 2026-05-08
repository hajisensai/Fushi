import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_ttu_source_page.dart';

void main() {
  group('TTU custom theme', () {
    test('writes a dark custom theme without requiring custom font color', () {
      final definition = buildTtuCustomThemeDefinition(dark: true);

      expect(definition['backgroundColor'], 'rgba(35,39,42,1)');
      expect(definition['fontColor'], 'rgba(255,255,255,0.87)');
    });

    test('uses explicit custom font color when provided', () {
      final definition = buildTtuCustomThemeDefinition(
        dark: false,
        fontColor: const Color(0xCC112233),
      );

      expect(definition['backgroundColor'], 'rgba(255,255,255,1)');
      expect(definition['fontColor'], 'rgba(17,34,51,0.80)');
      expect(definition['hintFuriganaFontColor'], 'rgba(17,34,51,0.38)');
    });

    test('serializes customThemes for TTU localStorage', () {
      final js = buildTtuCustomThemeJs(dark: true);

      expect(js, contains('window.localStorage.setItem("customThemes"'));
      expect(js, contains('custom-theme'));
      expect(js, contains('rgba(35,39,42,1)'));
    });

    test('reader chrome theme uses custom background and keeps seed primary',
        () {
      final base = ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF008577),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: Color(0xFF008577),
          thumbColor: Color(0xFF008577),
        ),
      );

      final theme = buildTtuReaderChromeTheme(
        base: base,
        surface: const Color(0xFFFFF3E0),
      );

      expect(theme.colorScheme.surface, const Color(0xFFFFF3E0));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFFFF3E0));
      expect(theme.bottomAppBarTheme.color, const Color(0xFFFFF3E0));
      expect(theme.bottomSheetTheme.backgroundColor, const Color(0xFFFFF3E0));
      expect(theme.colorScheme.primary, base.colorScheme.primary);
      expect(theme.sliderTheme.activeTrackColor, const Color(0xFF008577));
    });
  });

  group('Reader bridge injection gate', () {
    test('joins an in-flight injection instead of completing early', () async {
      final gate = ReaderTtuBridgeInjectionGate();
      final completer = Completer<void>();
      int runs = 0;

      final Future<void> first = gate.run(() {
        runs++;
        return completer.future;
      });
      final Future<void> second = gate.run(() {
        runs++;
        return Future<void>.value();
      });

      await Future<void>.delayed(Duration.zero);

      expect(runs, 1);
      expect(await isCompleted(second), isFalse);

      completer.complete();
      await Future.wait([first, second]);

      expect(runs, 1);
    });

    test('allows a new injection after the previous one finishes', () async {
      final gate = ReaderTtuBridgeInjectionGate();
      int runs = 0;

      await gate.run(() async {
        runs++;
      });
      await gate.run(() async {
        runs++;
      });

      expect(runs, 2);
    });
  });

  group('Reader bottom chrome reserve', () {
    test('keeps TTU page margin independent from Flutter chrome reserve', () {
      expect(
        resolveTtuPageMarginBottom(
          writingMode: 'vertical-rl',
          firstDimensionMargin: 12,
          secondDimensionMargin: 20,
        ),
        20,
      );
      expect(
        resolveTtuPageMarginBottom(
          writingMode: 'horizontal-tb',
          firstDimensionMargin: 12,
          secondDimensionMargin: 20,
        ),
        12,
      );
    });

    test('reserves the slot for a plain book when the play bar is visible', () {
      expect(
        shouldReserveReaderBottomChrome(
          showPlayBar: true,
        ),
        isTrue,
      );
    });

    test('does not reserve the slot when the play bar is hidden', () {
      expect(
        shouldReserveReaderBottomChrome(
          showPlayBar: false,
        ),
        isFalse,
      );
    });
  });

  group('Reader progress metrics', () {
    test('uses absolute horizontal position for vertical continuous mode', () {
      expect(
        resolveReaderProgressRatio(
          scrollPosition: -250,
          scrollExtent: 1000,
          viewportExtent: 500,
        ),
        0.5,
      );
    });

    test('clamps progress when scroll is past the rendered extent', () {
      expect(
        resolveReaderProgressRatio(
          scrollPosition: 750,
          scrollExtent: 1000,
          viewportExtent: 500,
        ),
        1,
      );
    });

    test('converts TTU zero-based page info to displayed page progress', () {
      expect(
        resolveDisplayedPageProgress(currentPage: 0, totalPages: 12),
        (1, 12),
      );
      expect(
        resolveDisplayedPageProgress(currentPage: 11, totalPages: 12),
        (12, 12),
      );
    });

    test('converts current section progress into full-book progress', () {
      expect(
        resolveFullBookReaderProgress(
          sectionChars: const [100, 200, 300],
          sectionIndex: 1,
          sectionCurrentChars: 100,
          sectionTotalChars: 200,
        ),
        (200, 600),
      );
    });

    test(
        'does not fall back to section progress while full-book data waits for TTU section',
        () {
      expect(
        resolveTopReaderProgress(
          sectionChars: const [100, 200, 300],
          sectionIndex: -1,
          sectionCurrentChars: 100,
          sectionTotalChars: 200,
        ),
        isNull,
      );
    });

    test('falls back to section progress when no full-book metadata exists',
        () {
      expect(
        resolveTopReaderProgress(
          sectionChars: const [],
          sectionIndex: -1,
          sectionCurrentChars: 100,
          sectionTotalChars: 200,
        ),
        (100, 200),
      );
    });

    test('preserves 0-length sections for index alignment', () {
      expect(
        parseReaderProgressSectionChars('[100, 0, -1, 200.9, "bad", 300]'),
        const [100, 0, 0, 200, 300],
      );
      expect(parseReaderProgressSectionChars('not json'), const <int>[]);
    });
  });

  group('resolveGlobalCharOffset', () {
    test('returns null for empty sectionChars', () {
      expect(
        resolveGlobalCharOffset(sectionChars: const [], globalOffset: 0),
        isNull,
      );
    });

    test('returns null for out-of-range offset', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 200], globalOffset: 301),
        isNull,
      );
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 200], globalOffset: -1),
        isNull,
      );
    });

    test('resolves offset within first section', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 200, 300], globalOffset: 50),
        (0, 50),
      );
    });

    test('resolves offset at section boundary', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 200, 300], globalOffset: 100),
        (1, 0),
      );
    });

    test('skips 0-length section correctly', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 0, 200], globalOffset: 150),
        (2, 50),
      );
    });

    test('offset at 0-length section boundary lands on next section', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 0, 200], globalOffset: 100),
        (2, 0),
      );
    });

    test('offset == total lands on last section end', () {
      expect(
        resolveGlobalCharOffset(
            sectionChars: const [100, 200], globalOffset: 300),
        (1, 200),
      );
    });
  });
}

Future<bool> isCompleted(Future<void> future) async {
  bool completed = false;
  unawaited(future.then((_) {
    completed = true;
  }));
  await Future<void>.delayed(Duration.zero);
  return completed;
}
